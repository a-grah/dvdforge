// Multi-pass, resumable title reader: the core of dvdForge's bitrot defense.
//
//   Pass 1 (sweep)  Read in large chunks. A chunk that fails is marked pending
//                   and skipped, so healthy data comes off before marginal
//                   areas are stressed.
//   Pass 2 (scrape) Re-read pending sectors one at a time at minimum drive
//                   speed, alternating direction, up to `retries` attempts.
//                   Sectors that never read are zero-filled and marked bad.
//                   Does nothing on a healthy disc.
//   Pass 3 (verify) Optional. Re-read every good sector and compare with the
//                   staging file; on mismatch, keep re-reading until two reads
//                   agree. Catches drives that return wrong data without an error.
//
// Data goes to a staging file (the title's cells concatenated in playback
// order) and a sector map is saved alongside it, so a cancelled or crashed rip
// resumes where it left off.

#include "Internal.hpp"
#include "SectorSource.hpp"

#include <fcntl.h>
#include <sys/stat.h>
#include <unistd.h>

#include <algorithm>
#include <atomic>
#include <chrono>
#include <cstdio>
#include <cstring>
#include <filesystem>
#include <fstream>
#include <mutex>
#include <optional>
#include <sstream>

namespace fs = std::filesystem;

namespace dc {

namespace {

using Clock = std::chrono::steady_clock;

/// Per-sector states with running totals.
class SectorMap {
public:
    explicit SectorMap(uint64_t total = 0) : states_(total, SectorState::untried) {
        counts_[static_cast<int>(SectorState::untried)] = total;
    }

    uint64_t size() const { return states_.size(); }
    SectorState operator[](uint64_t i) const { return states_[i]; }
    uint64_t count(SectorState s) const { return counts_[static_cast<int>(s)]; }

    void set(uint64_t i, SectorState s) {
        --counts_[static_cast<int>(states_[i])];
        ++counts_[static_cast<int>(s)];
        states_[i] = s;
    }

    void setRange(uint64_t first, uint64_t n, SectorState s) {
        for (uint64_t i = first; i < first + n; ++i) set(i, s);
    }

    /// ddrescue-style text: a header, then one "start count state" line per run.
    bool save(const fs::path& path, int title) const {
        fs::path tmp = path;
        tmp += ".tmp";
        {
            std::ofstream out(tmp, std::ios::trunc);
            if (!out) return false;
            out << "dvdforge-sectormap 1\ntitle " << title << "\ntotal " << states_.size() << "\n";
            for (uint64_t i = 0; i < states_.size();) {
                uint64_t j = i;
                while (j < states_.size() && states_[j] == states_[i]) ++j;
                out << i << ' ' << (j - i) << ' ' << static_cast<int>(states_[i]) << '\n';
                i = j;
            }
            if (!out.flush()) return false;
        }
        std::error_code ec;
        fs::rename(tmp, path, ec);
        return !ec;
    }

    static std::optional<SectorMap> load(const fs::path& path, int title, uint64_t total) {
        std::ifstream in(path);
        std::string magic, key;
        int version = 0, fileTitle = 0;
        uint64_t fileTotal = 0;
        if (!(in >> magic >> version >> key >> fileTitle >> key >> fileTotal)) return std::nullopt;
        if (magic != "dvdforge-sectormap" || version != 1 || fileTitle != title || fileTotal != total)
            return std::nullopt;
        SectorMap map(total);
        uint64_t start, n;
        int state;
        while (in >> start >> n >> state) {
            if (start + n > total || state < 0 || state > static_cast<int>(SectorState::unstable))
                return std::nullopt;
            map.setRange(start, n, static_cast<SectorState>(state));
        }
        return map;
    }

private:
    std::vector<SectorState> states_;
    uint64_t counts_[5] = {};
};

/// One cell, placed in both the title's linear sector space and the VTS.
struct Extent {
    uint64_t titleStart;
    uint32_t lba;
    uint32_t count;
    uint64_t startTicks;
    uint64_t durationTicks;
    int chapter;
};

std::string twoDigits(int n) {
    char buf[8];
    snprintf(buf, sizeof buf, "%02d", n);
    return buf;
}

} // namespace

class ReadJob {
public:
    ReadJob(std::string discPath, int titleNumber, std::string stagingDir, ReadOptions options,
            std::optional<FaultPlan> faults)
        : discPath_(std::move(discPath)), titleNumber_(titleNumber), stagingDir_(std::move(stagingDir)),
          options_(options), faults_(std::move(faults)) {
        options_.retries = std::max(options_.retries, 1);
        options_.chunkSectors = std::clamp<uint32_t>(options_.chunkSectors, 1, 4096);
    }

    ~ReadJob() {
        if (fd_ >= 0) close(fd_);
    }

    ReadResult run();

    ReadProgress progress() {
        std::lock_guard lock(mutex_);
        ReadProgress p = progress_;
        p.totalSectors = map_.size();
        p.good = map_.count(SectorState::good);
        p.bad = map_.count(SectorState::bad);
        p.pending = map_.count(SectorState::pending);
        p.unstable = map_.count(SectorState::unstable);
        return p;
    }

    std::vector<SectorState> summary(int buckets) {
        std::lock_guard lock(mutex_);
        std::vector<SectorState> out;
        if (buckets <= 0 || map_.size() == 0) return out;
        out.reserve(buckets);
        // Severity order for "worst state in bucket".
        auto rank = [](SectorState s) {
            switch (s) {
            case SectorState::good: return 0;
            case SectorState::untried: return 1;
            case SectorState::pending: return 2;
            case SectorState::unstable: return 3;
            case SectorState::bad: return 4;
            }
            return 0;
        };
        for (int b = 0; b < buckets; ++b) {
            uint64_t first = map_.size() * b / buckets;
            uint64_t last = std::max(first + 1, map_.size() * (b + 1) / buckets);
            SectorState worst = map_[first];
            for (uint64_t i = first; i < last && i < map_.size(); ++i)
                if (rank(map_[i]) > rank(worst)) worst = map_[i];
            out.push_back(worst);
        }
        return out;
    }

    void cancel() { cancelled_ = true; }

private:
    // Setup
    bool prepare(ReadResult& result);
    // Passes
    void sweep();
    void scrape();
    void verify();
    bool shouldVerify() const;
    // I/O
    bool readSectors(uint64_t titleSector, uint32_t count, uint8_t* buf);
    bool writeSectors(uint64_t titleSector, uint32_t count, const uint8_t* buf);
    bool readStaged(uint64_t titleSector, uint32_t count, uint8_t* buf);
    const Extent& extentFor(uint64_t titleSector) const;
    // Bookkeeping
    void setState(uint64_t first, uint64_t n, SectorState s);
    void beginPass(ReadPass pass, uint64_t total);
    void advance(uint64_t n);
    void noteRead(uint64_t sectors, Clock::duration elapsed);
    void saveMapIfDue(bool force = false);
    bool isCancelled() const { return cancelled_; }
    std::vector<DamagedRange> damage() const;

    std::string discPath_;
    int titleNumber_;
    std::string stagingDir_;
    ReadOptions options_;
    std::optional<FaultPlan> faults_;

    LogSink log_;
    DvdPtr dvd_;
    std::unique_ptr<SectorSource> source_;
    std::vector<Extent> extents_;
    Title title_;
    fs::path stagingPath_, mapPath_;
    int fd_ = -1;

    std::mutex mutex_;  // guards map_ and progress_ against progress()/summary()
    SectorMap map_;
    ReadProgress progress_;

    std::atomic<bool> cancelled_{false};
    uint64_t errorsThisRun_ = 0;
    uint64_t sectorsRead_ = 0;
    uint64_t repaired_ = 0;
    bool hadDamageBefore_ = false;
    Clock::time_point lastMapSave_ = Clock::now();
    Clock::time_point rateWindowStart_ = Clock::now();
    uint64_t rateWindowBytes_ = 0;
};

// MARK: - Setup

bool ReadJob::prepare(ReadResult& result) {
    dvd_ = openDvd(discPath_, log_);
    if (!dvd_) {
        result.error = "Could not open " + discPath_ + " as a DVD.";
        return false;
    }
    DiscInfo info = readDiscInfo(dvd_.get(), log_);
    if (!info.ok) {
        result.error = info.error;
        return false;
    }
    auto title = std::find_if(info.titles.begin(), info.titles.end(),
                              [&](const Title& t) { return t.number == titleNumber_; });
    if (title == info.titles.end()) {
        result.error = "Title " + std::to_string(titleNumber_) + " is not on this disc.";
        return false;
    }

    title_ = *title;
    uint64_t pos = 0, ticks = 0;
    for (const CellRange& c : title->cells) {
        uint32_t n = c.lastSector - c.firstSector + 1;
        extents_.push_back({pos, c.firstSector, n, ticks, c.durationTicks, c.chapter});
        pos += n;
        ticks += c.durationTicks;
    }

    auto dvdSource = std::make_unique<DvdSectorSource>(dvd_.get(), title->titleSet, discPath_);
    if (!dvdSource->isOpen()) {
        result.error = "Could not open the title's VOB files.";
        return false;
    }
    source_ = faults_ ? std::unique_ptr<SectorSource>(
                            std::make_unique<FaultySectorSource>(std::move(dvdSource), *faults_))
                      : std::move(dvdSource);

    std::error_code ec;
    fs::create_directories(stagingDir_, ec);
    if (ec) {
        result.error = "Could not create " + stagingDir_ + ": " + ec.message();
        return false;
    }
    stagingPath_ = fs::path(stagingDir_) / ("title-" + twoDigits(titleNumber_) + ".vob");
    mapPath_ = fs::path(stagingDir_) / ("title-" + twoDigits(titleNumber_) + ".map");
    result.stagingPath = stagingPath_.string();

    // Resume only if both the map and a staging file of the right size exist.
    uint64_t bytes = pos * kSectorSize;
    std::optional<SectorMap> saved;
    if (fs::exists(stagingPath_) && fs::file_size(stagingPath_, ec) == bytes)
        saved = SectorMap::load(mapPath_, titleNumber_, pos);
    {
        std::lock_guard lock(mutex_);
        map_ = saved ? std::move(*saved) : SectorMap(pos);
        // Give previously unreadable sectors another chance (a cleaned disc, another drive).
        hadDamageBefore_ = map_.count(SectorState::bad) || map_.count(SectorState::unstable);
        for (uint64_t i = 0; i < map_.size(); ++i)
            if (map_[i] == SectorState::bad) map_.set(i, SectorState::pending);
    }
    result.resumed = saved.has_value();

    fd_ = open(stagingPath_.c_str(), O_RDWR | O_CREAT | (saved ? 0 : O_TRUNC), 0644);
    if (fd_ < 0 || ftruncate(fd_, static_cast<off_t>(bytes)) != 0) {
        result.error = "Could not create the staging file " + stagingPath_.string() + ".";
        return false;
    }
    return true;
}

// MARK: - Passes

void ReadJob::sweep() {
    beginPass(ReadPass::sweep, map_.size());
    std::vector<uint8_t> buf(size_t(options_.chunkSectors) * kSectorSize);
    for (const Extent& e : extents_) {
        for (uint64_t off = 0; off < e.count && !isCancelled(); off += options_.chunkSectors) {
            uint64_t chunkStart = e.titleStart + off;
            uint64_t chunkEnd = std::min<uint64_t>(chunkStart + options_.chunkSectors, e.titleStart + e.count);
            // Read each run of untried sectors (on resume, good ones are skipped).
            for (uint64_t i = chunkStart; i < chunkEnd;) {
                if (map_[i] != SectorState::untried) { ++i; continue; }
                uint64_t j = i;
                while (j < chunkEnd && map_[j] == SectorState::untried) ++j;
                auto n = static_cast<uint32_t>(j - i);
                if (readSectors(i, n, buf.data()) && writeSectors(i, n, buf.data()))
                    setState(i, n, SectorState::good);
                else
                    setState(i, n, SectorState::pending);
                i = j;
            }
            advance(chunkEnd - chunkStart);
            saveMapIfDue();
        }
    }
}

void ReadJob::scrape() {
    std::vector<uint64_t> pending;
    for (uint64_t i = 0; i < map_.size(); ++i)
        if (map_[i] == SectorState::pending) pending.push_back(i);
    beginPass(ReadPass::scrape, pending.size() * options_.retries);
    if (pending.empty()) return;

    source_->setSlow(true);
    std::vector<uint8_t> buf(kSectorSize);
    for (int attempt = 0; attempt < options_.retries && !pending.empty() && !isCancelled(); ++attempt) {
        // Alternate direction so a damaged area is approached from both sides.
        if (attempt % 2 == 1) std::reverse(pending.begin(), pending.end());
        std::vector<uint64_t> stillPending;
        for (uint64_t s : pending) {
            if (isCancelled()) { stillPending.push_back(s); continue; }
            if (readSectors(s, 1, buf.data()) && writeSectors(s, 1, buf.data()))
                setState(s, 1, SectorState::good);
            else
                stillPending.push_back(s);
            advance(1);
            saveMapIfDue();
        }
        if (attempt % 2 == 1) std::reverse(stillPending.begin(), stillPending.end());
        pending = std::move(stillPending);
    }
    source_->setSlow(false);

    if (isCancelled()) return;
    // Out of retries: zero-fill so the demuxer resyncs at the next pack.
    std::vector<uint8_t> zeros(kSectorSize, 0);
    for (uint64_t s : pending) {
        writeSectors(s, 1, zeros.data());
        setState(s, 1, SectorState::bad);
    }
    std::lock_guard lock(mutex_);
    progress_.passDone = progress_.passTotal;
}

bool ReadJob::shouldVerify() const {
    switch (options_.verify) {
    case VerifyMode::off: return false;
    case VerifyMode::always: return true;
    case VerifyMode::automatic: return errorsThisRun_ > 0 || hadDamageBefore_;
    }
    return false;
}

void ReadJob::verify() {
    auto verifiable = [&](uint64_t i) {
        return map_[i] == SectorState::good || map_[i] == SectorState::unstable;
    };
    uint64_t total = 0;
    for (uint64_t i = 0; i < map_.size(); ++i) total += verifiable(i);
    beginPass(ReadPass::verify, total);

    std::vector<uint8_t> fresh(size_t(options_.chunkSectors) * kSectorSize);
    std::vector<uint8_t> staged(fresh.size());

    // Resolves one sector by majority vote among the staged copy, the
    // mismatching fresh copy and up to `retries` further reads.
    auto vote = [&](uint64_t s, const uint8_t* stagedCopy, const uint8_t* freshCopy) {
        std::vector<std::vector<uint8_t>> copies{{stagedCopy, stagedCopy + kSectorSize},
                                                 {freshCopy, freshCopy + kSectorSize}};
        std::vector<uint8_t> extra(kSectorSize);
        std::optional<size_t> winner;  // index into copies
        for (int attempt = 0; attempt < options_.retries && !winner && !isCancelled(); ++attempt) {
            if (!readSectors(s, 1, extra.data())) continue;
            for (size_t c = 0; c < copies.size() && !winner; ++c)
                if (copies[c] == extra) winner = c;
            copies.push_back(extra);
        }
        if (isCancelled()) return;
        if (!winner) {
            setState(s, 1, SectorState::unstable);  // keep the staged copy as best guess
            return;
        }
        if (*winner != 0) {
            writeSectors(s, 1, copies[*winner].data());
            ++repaired_;
        }
        setState(s, 1, SectorState::good);
    };

    for (const Extent& e : extents_) {
        for (uint64_t off = 0; off < e.count && !isCancelled(); off += options_.chunkSectors) {
            uint64_t chunkStart = e.titleStart + off;
            uint64_t chunkEnd = std::min<uint64_t>(chunkStart + options_.chunkSectors, e.titleStart + e.count);
            for (uint64_t i = chunkStart; i < chunkEnd && !isCancelled();) {
                if (!verifiable(i)) { ++i; continue; }
                uint64_t j = i;
                while (j < chunkEnd && verifiable(j)) ++j;
                auto n = static_cast<uint32_t>(j - i);
                if (!readStaged(i, n, staged.data())) { i = j; continue; }
                if (readSectors(i, n, fresh.data())) {
                    for (uint32_t k = 0; k < n; ++k) {
                        const uint8_t* a = staged.data() + size_t(k) * kSectorSize;
                        const uint8_t* b = fresh.data() + size_t(k) * kSectorSize;
                        if (std::memcmp(a, b, kSectorSize) != 0) vote(i + k, a, b);
                    }
                } else {
                    // The run read fine before; check it sector by sector.
                    for (uint32_t k = 0; k < n && !isCancelled(); ++k) {
                        uint8_t* b = fresh.data() + size_t(k) * kSectorSize;
                        const uint8_t* a = staged.data() + size_t(k) * kSectorSize;
                        if (readSectors(i + k, 1, b) && std::memcmp(a, b, kSectorSize) != 0) vote(i + k, a, b);
                    }
                }
                advance(n);
                i = j;
            }
            saveMapIfDue();
        }
    }
}

// MARK: - I/O

const Extent& ReadJob::extentFor(uint64_t titleSector) const {
    auto it = std::upper_bound(extents_.begin(), extents_.end(), titleSector,
                               [](uint64_t s, const Extent& e) { return s < e.titleStart; });
    return *(it - 1);
}

bool ReadJob::readSectors(uint64_t titleSector, uint32_t count, uint8_t* buf) {
    const Extent& e = extentFor(titleSector);
    auto lba = static_cast<uint32_t>(e.lba + (titleSector - e.titleStart));
    auto start = Clock::now();
    bool ok = source_->read(lba, count, buf);
    if (ok) {
        sectorsRead_ += count;
        noteRead(count, Clock::now() - start);
    } else {
        ++errorsThisRun_;
        std::lock_guard lock(mutex_);
        ++progress_.readErrors;
    }
    if (faults_ && faults_->cancelAfterSectors && sectorsRead_ >= faults_->cancelAfterSectors) cancel();
    return ok;
}

bool ReadJob::writeSectors(uint64_t titleSector, uint32_t count, const uint8_t* buf) {
    size_t bytes = size_t(count) * kSectorSize;
    return pwrite(fd_, buf, bytes, static_cast<off_t>(titleSector * kSectorSize)) == static_cast<ssize_t>(bytes);
}

bool ReadJob::readStaged(uint64_t titleSector, uint32_t count, uint8_t* buf) {
    size_t bytes = size_t(count) * kSectorSize;
    return pread(fd_, buf, bytes, static_cast<off_t>(titleSector * kSectorSize)) == static_cast<ssize_t>(bytes);
}

// MARK: - Bookkeeping

void ReadJob::setState(uint64_t first, uint64_t n, SectorState s) {
    std::lock_guard lock(mutex_);
    map_.setRange(first, n, s);
}

void ReadJob::beginPass(ReadPass pass, uint64_t total) {
    std::lock_guard lock(mutex_);
    progress_.pass = pass;
    progress_.passDone = 0;
    progress_.passTotal = total;
}

void ReadJob::advance(uint64_t n) {
    std::lock_guard lock(mutex_);
    progress_.passDone = std::min(progress_.passDone + n, progress_.passTotal);
    progress_.repaired = repaired_;
}

void ReadJob::noteRead(uint64_t sectors, Clock::duration) {
    rateWindowBytes_ += sectors * kSectorSize;
    auto now = Clock::now();
    double secs = std::chrono::duration<double>(now - rateWindowStart_).count();
    if (secs >= 1.0) {
        std::lock_guard lock(mutex_);
        progress_.bytesPerSecond = rateWindowBytes_ / secs;
        rateWindowBytes_ = 0;
        rateWindowStart_ = now;
    }
}

void ReadJob::saveMapIfDue(bool force) {
    auto now = Clock::now();
    if (!force && now - lastMapSave_ < std::chrono::seconds(5)) return;
    lastMapSave_ = now;
    fsync(fd_);  // data before map, so the map never claims sectors that aren't on disk
    std::lock_guard lock(mutex_);
    map_.save(mapPath_, titleNumber_);
}

std::vector<DamagedRange> ReadJob::damage() const {
    std::vector<DamagedRange> out;
    for (uint64_t i = 0; i < map_.size();) {
        SectorState s = map_[i];
        if (s != SectorState::bad && s != SectorState::unstable) { ++i; continue; }
        uint64_t j = i;
        while (j < map_.size() && map_[j] == s) ++j;
        const Extent& e = extentFor(i);
        // Linear interpolation within the cell; good to about a second.
        uint64_t ticks = e.startTicks + (e.count ? e.durationTicks * (i - e.titleStart) / e.count : 0);
        out.push_back({.firstSector = i, .sectorCount = j - i, .state = s, .startTicks = ticks,
                       .chapter = e.chapter});
        i = j;
    }
    return out;
}

ReadResult ReadJob::run() {
    ReadResult result;
    if (!prepare(result)) return result;

    sweep();
    if (!isCancelled()) scrape();
    if (!isCancelled() && shouldVerify()) {
        result.verifyRan = true;
        verify();
    }
    saveMapIfDue(/*force=*/true);

    {
        std::lock_guard lock(mutex_);
        progress_.pass = ReadPass::done;
        progress_.repaired = repaired_;
    }
    result.cancelled = isCancelled();
    result.completed = !result.cancelled;
    result.totalSectors = map_.size();
    result.good = map_.count(SectorState::good);
    result.bad = map_.count(SectorState::bad);
    result.unstable = map_.count(SectorState::unstable);
    result.repaired = repaired_;
    result.readErrors = progress_.readErrors;
    result.sectorsReadFromDisc = sectorsRead_;
    result.damage = damage();
    result.title = title_;
    return result;
}

// MARK: - Public API

ReadJob* createReadJob(const std::string& discPath, int titleNumber, const std::string& stagingDir,
                       const ReadOptions& options) {
    return new ReadJob(discPath, titleNumber, stagingDir, options, std::nullopt);
}

ReadJob* createReadJobWithFaults(const std::string& discPath, int titleNumber, const std::string& stagingDir,
                                 const ReadOptions& options, const FaultPlan& faults) {
    return new ReadJob(discPath, titleNumber, stagingDir, options, faults);
}

ReadResult runReadJob(ReadJob* job) { return job->run(); }
ReadProgress readJobProgress(ReadJob* job) { return job->progress(); }
std::vector<SectorState> readJobMapSummary(ReadJob* job, int buckets) { return job->summary(buckets); }
void cancelReadJob(ReadJob* job) { job->cancel(); }
void destroyReadJob(ReadJob* job) { delete job; }

} // namespace dc
