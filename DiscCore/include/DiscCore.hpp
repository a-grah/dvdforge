// DiscCore: the C++ engine behind dvdForge.
//
// This header is the only surface Swift sees. It deliberately exposes plain
// value types (std::string, std::vector, structs of integers) and never any
// libdvdread or FFmpeg types, so the Swift side stays insulated from the C APIs.
#pragma once

#include <cstdint>
#include <string>
#include <vector>

namespace dc {

/// Versions of the vendored native libraries, for the About box and rip reports.
struct LibraryVersions {
    std::string libdvdread;
    std::string libdvdcss;
    std::string libavformat;
    std::string libavcodec;
};

LibraryVersions libraryVersions();

/// True if libdvdread can open `path` as a DVD: a raw device (/dev/rdiskN),
/// a mounted VIDEO_TS folder, or an ISO image.
bool canOpenDisc(const std::string& path);

// MARK: - Disc structure

/// All times are in 90 kHz ticks (the MPEG system clock), so they can be used
/// directly for timestamp re-basing when muxing.
inline constexpr uint64_t kTicksPerSecond = 90'000;

/// Converts an IFO playback time (BCD hour/minute/second plus the frame byte,
/// whose top two bits give the rate) to 90 kHz ticks. The fields are timecode:
/// for NTSC they count 30 frames per "second" although video runs at 29.97,
/// so a timecode second lasts 1.001 real seconds.
uint64_t dvdTimeToTicks(uint8_t hour, uint8_t minute, uint8_t second, uint8_t frameByte);

enum class AudioCodec : uint8_t { ac3, dts, lpcm, mpeg, unknown };

enum class TrackPurpose : uint8_t { normal, visuallyImpaired, commentary, other };

struct AudioTrack {
    int number = 0;            ///< DVD audio stream number (0–7).
    int streamId = 0;          ///< MPEG-PS stream id: 0x80+n AC3, 0x88+n DTS, 0xA0+n LPCM, 0xC0+n MPEG.
    AudioCodec codec = AudioCodec::unknown;
    int channels = 0;
    int sampleRate = 0;
    int bitsPerSample = 0;     ///< LPCM only (16/20/24); 0 otherwise.
    std::string language;      ///< ISO 639-1 code ("en"), empty if unspecified.
    TrackPurpose purpose = TrackPurpose::normal;
};

struct SubtitleTrack {
    int number = 0;            ///< DVD subpicture stream number (0–31) as shown in menus.
    int streamId = 0;          ///< 0x20 + physical stream, for the title's display mode.
    std::string language;
    TrackPurpose purpose = TrackPurpose::normal;
};

struct Chapter {
    int number = 0;
    uint64_t startTicks = 0;
    uint64_t durationTicks = 0;
};

/// A contiguous run of sectors (inclusive) in the title's VTS, in playback order.
struct CellRange {
    uint32_t firstSector = 0;
    uint32_t lastSector = 0;
    uint64_t durationTicks = 0;
    int chapter = 0;           ///< Chapter this cell belongs to.
    /// The MPEG clock restarts at this cell (the IFO's STC discontinuity flag).
    bool clockRestarts = false;
};

enum class AspectRatio : uint8_t { fourByThree, sixteenByNine, unknown };

struct Title {
    int number = 0;            ///< Title number as the disc's menus count them (1-based).
    int titleSet = 0;          ///< VTS number.
    int angles = 1;
    uint64_t durationTicks = 0;
    uint64_t sectorCount = 0;  ///< Sectors that will be read for angle 1.

    int width = 0;
    int height = 0;
    bool pal = false;
    AspectRatio aspect = AspectRatio::unknown;

    std::vector<Chapter> chapters;
    std::vector<AudioTrack> audio;
    std::vector<SubtitleTrack> subtitles;
    std::vector<CellRange> cells;
    std::vector<uint32_t> palette;  ///< 16 subtitle colours, 0x00YYCrCb, from the title's PGC.

    bool isMainFeature = false;
    /// Plays exactly the same cells as an earlier title (menus' "play all"
    /// duplicates, or fake playlists on structure-protected discs).
    bool duplicatesEarlierTitle = false;
};

using TitleList = std::vector<Title>;  // named so Swift can spell the type

struct DiscInfo {
    bool ok = false;
    std::string error;         ///< Set when ok == false.
    std::string volumeLabel;
    std::string discId;        ///< 32 hex chars; MD5 over the IFOs, stable across rips.
    TitleList titles;
    std::vector<std::string> log;  ///< libdvdread warnings/errors collected while reading.
};

/// Reads the disc structure. Blocking: on a CSS disc the first open cracks
/// the keys, which can take a while. Call from a background thread.
DiscInfo readDiscInfo(const std::string& path);

/// Sets isMainFeature / duplicatesEarlierTitle. Exposed for tests; readDiscInfo
/// already calls it.
void classifyTitles(TitleList& titles);

// MARK: - Resilient title reading

inline constexpr uint32_t kSectorSize = 2048;

/// When to run the verification re-read (pass 3).
enum class VerifyMode : uint8_t {
    off,
    automatic,  ///< Only if passes 1–2 hit any read error (default).
    always,
};

struct ReadOptions {
    VerifyMode verify = VerifyMode::automatic;
    int retries = 8;                ///< Per-sector attempts in pass 2 and pass 3 voting.
    uint32_t chunkSectors = 512;    ///< Pass 1 read size (1 MiB).
};

/// State of each sector of the title, in title (playback) order.
enum class SectorState : uint8_t {
    untried = 0,
    good = 1,
    pending = 2,     ///< In a chunk that failed in pass 1; not yet scraped.
    bad = 3,         ///< Unreadable after all retries; zero-filled in the staging file.
    unstable = 4,    ///< Reads disagreed and no value won a majority.
};

enum class ReadPass : uint8_t { opening, sweep, scrape, verify, done };

struct ReadProgress {
    ReadPass pass = ReadPass::opening;
    uint64_t passDone = 0;          ///< Sectors handled in the current pass.
    uint64_t passTotal = 0;
    uint64_t totalSectors = 0;
    uint64_t good = 0;
    uint64_t bad = 0;
    uint64_t pending = 0;
    uint64_t unstable = 0;
    uint64_t repaired = 0;          ///< Sectors corrected by the verification pass.
    uint64_t readErrors = 0;        ///< Failed read calls so far (all passes).
    double bytesPerSecond = 0;      ///< Recent read throughput.
};

/// A run of unreadable or unstable sectors, located in the title's timeline.
struct DamagedRange {
    uint64_t firstSector = 0;       ///< Title-relative.
    uint64_t sectorCount = 0;
    SectorState state = SectorState::bad;
    uint64_t startTicks = 0;        ///< Approximate playback position.
    int chapter = 0;
};

struct ReadResult {
    bool completed = false;
    bool cancelled = false;
    std::string error;
    std::string stagingPath;        ///< The title's data, cells concatenated in playback order.
    uint64_t totalSectors = 0;
    uint64_t good = 0;
    uint64_t bad = 0;
    uint64_t unstable = 0;
    uint64_t repaired = 0;
    uint64_t readErrors = 0;
    uint64_t sectorsReadFromDisc = 0;  ///< Less than the total when a rip resumed.
    bool verifyRan = false;
    bool resumed = false;
    std::vector<DamagedRange> damage;
    Title title;                    ///< The title's structure, as read from this disc (for remuxing).
};

/// Simulated media faults, keyed by VTS-relative sector. Tests only.
struct FaultPlan {
    std::vector<uint32_t> hardBad;        ///< Always fail.
    std::vector<uint32_t> intermittent;   ///< Fail the first `intermittentFailures` reads.
    int intermittentFailures = 2;
    std::vector<uint32_t> flipped;        ///< First read returns corrupted data, silently.
    uint64_t cancelAfterSectors = 0;      ///< Cancel the job once this many sectors were read.
};

/// A read of one title into a staging file. Opaque; drive it with the functions
/// below. `run` blocks, so call it on a background thread; `progress` and
/// `cancel` are safe to call from any thread while it runs.
class ReadJob;

/// Staging files go in `stagingDir` as title-NN.vob plus a title-NN.map sector
/// map, which lets an interrupted rip resume without re-reading good sectors.
ReadJob* createReadJob(const std::string& discPath, int titleNumber, const std::string& stagingDir,
                       const ReadOptions& options);
ReadJob* createReadJobWithFaults(const std::string& discPath, int titleNumber,
                                 const std::string& stagingDir, const ReadOptions& options,
                                 const FaultPlan& faults);
ReadResult runReadJob(ReadJob* job);
ReadProgress readJobProgress(ReadJob* job);
/// The sector map squeezed into `buckets` cells, each the worst state inside it,
/// for drawing.
std::vector<SectorState> readJobMapSummary(ReadJob* job, int buckets);
void cancelReadJob(ReadJob* job);
void destroyReadJob(ReadJob* job);

// MARK: - Lossless remux to Matroska

using IntList = std::vector<int>;  // named so Swift can spell the type

struct RemuxRequest {
    std::string stagingPath;        ///< From ReadResult.
    std::string outputPath;         ///< .mkv; written to a temp name and renamed on success.
    Title title;                    ///< From ReadResult.
    IntList audioTracks;            ///< AudioTrack::number values to keep, in output order.
    IntList subtitleTracks;         ///< SubtitleTrack::number values to keep, in output order.
    int defaultAudioTrack = -1;     ///< AudioTrack::number to flag as default; -1 = the first kept.
    std::string movieTitle;
    // Provenance written as Matroska tags.
    std::string discId;
    std::string driveModel;
    uint64_t badSectors = 0;
    uint64_t unstableSectors = 0;
};

struct RemuxProgress {
    double fraction = 0;            ///< Of the staging file consumed.
};

struct RemuxResult {
    bool completed = false;
    bool cancelled = false;
    std::string error;
    std::string outputPath;
    uint64_t durationTicks = 0;     ///< Of the output video track.
    int timestampDiscontinuities = 0;  ///< Cell boundaries where timestamps were re-based.
    int demuxSegments = 0;          ///< Clock segments (from the IFO) demuxed separately.
    std::vector<std::string> warnings;
};

/// Same pattern as ReadJob: `run` blocks; `progress`/`cancel` are thread-safe.
class RemuxJob;

RemuxJob* createRemuxJob(const RemuxRequest& request);
RemuxResult runRemuxJob(RemuxJob* job);
RemuxProgress remuxJobProgress(RemuxJob* job);
void cancelRemuxJob(RemuxJob* job);
void destroyRemuxJob(RemuxJob* job);

/// "en" → "eng" (ISO 639-2/B, as Matroska expects); "und" if unknown.
std::string matroskaLanguage(const std::string& iso639_1);

} // namespace dc
