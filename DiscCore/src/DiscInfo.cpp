#include "Internal.hpp"

#include <cstdarg>
#include <cstdio>
#include <map>
#include <memory>

#include <dvdread/dvd_reader.h>
#include <dvdread/ifo_read.h>
#include <dvdread/ifo_types.h>

namespace dc {

namespace {

// MARK: - libdvdread plumbing

void logCallback(void* priv, dvd_logger_level_t level, const char* fmt, va_list args) {
    if (level == DVD_LOGGER_LEVEL_DEBUG || level == DVD_LOGGER_LEVEL_INFO) return;
    char buf[512];
    vsnprintf(buf, sizeof buf, fmt, args);
    static_cast<LogSink*>(priv)->lines.emplace_back(buf);
}

struct IfoCloser {
    void operator()(ifo_handle_t* i) const { ifoClose(i); }
};
using IfoPtr = std::unique_ptr<ifo_handle_t, IfoCloser>;

// MARK: - Field decoding

int fromBcd(uint8_t v) { return (v >> 4) * 10 + (v & 0x0f); }

/// dvd_time_t → 90 kHz ticks. The two high bits of frame_u give the frame rate
/// (01 = 25 fps, 11 = 29.97 fps); the rest is a BCD frame count.
uint64_t ticksFromDvdTime(const dvd_time_t& t) {
    uint64_t seconds = fromBcd(t.hour) * 3600ULL + fromBcd(t.minute) * 60ULL + fromBcd(t.second);
    uint64_t frames = fromBcd(t.frame_u & 0x3f);
    uint64_t ticksPerFrame = ((t.frame_u >> 6) == 1) ? 3600 : 3003;
    return seconds * kTicksPerSecond + frames * ticksPerFrame;
}

std::string language(uint16_t code) {
    if (code == 0 || code == 0xffff) return {};
    char c[3] = {static_cast<char>(code >> 8), static_cast<char>(code & 0xff), 0};
    return c;
}

TrackPurpose audioPurpose(uint8_t ext) {
    switch (ext) {
    case DVD_AUDIO_CODE_EXT_UNSPECIFIED:
    case DVD_AUDIO_CODE_EXT_NORMAL: return TrackPurpose::normal;
    case DVD_AUDIO_CODE_EXT_VISUALLY_IMPAIRED: return TrackPurpose::visuallyImpaired;
    case DVD_AUDIO_CODE_EXT_DIRECTOR:
    case DVD_AUDIO_CODE_EXT_ALT_DIRECTOR: return TrackPurpose::commentary;
    default: return TrackPurpose::other;
    }
}

TrackPurpose subtitlePurpose(uint8_t ext) {
    // Subpicture code extensions (SPRM 19): 1–3 caption sizes, 5–7 children's,
    // 9 forced, 13–15 director's comments.
    if (ext >= 13 && ext <= 15) return TrackPurpose::commentary;
    if (ext <= 7) return TrackPurpose::normal;
    return TrackPurpose::other;
}

std::string hex(const unsigned char* bytes, size_t n) {
    static const char* digits = "0123456789abcdef";
    std::string s;
    for (size_t i = 0; i < n; ++i) {
        s += digits[bytes[i] >> 4];
        s += digits[bytes[i] & 0x0f];
    }
    return s;
}

// MARK: - Title assembly

pgc_t* pgcAt(ifo_handle_t* vts, int pgcn) {
    pgcit_t* pgcit = vts->vts_pgcit;
    if (!pgcit || pgcn < 1 || pgcn > pgcit->nr_of_pgci_srp) return nullptr;
    return pgcit->pgci_srp[pgcn - 1].pgc;
}

void fillStreams(Title& title, ifo_handle_t* vts, pgc_t* pgc) {
    const vtsi_mat_t* mat = vts->vtsi_mat;
    const video_attr_t& video = mat->vts_video_attr;

    title.pal = video.video_format == 1;
    title.height = title.pal ? 576 : 480;
    switch (video.picture_size) {
    case 0: title.width = 720; break;
    case 1: title.width = 704; break;
    case 2: title.width = 352; break;
    default: title.width = 352; title.height /= 2; break;
    }
    title.aspect = video.display_aspect_ratio == 0   ? AspectRatio::fourByThree
                   : video.display_aspect_ratio == 3 ? AspectRatio::sixteenByNine
                                                     : AspectRatio::unknown;

    for (int i = 0; i < mat->nr_of_vts_audio_streams && i < 8; ++i) {
        if (!(pgc->audio_control[i] & 0x8000)) continue;  // not present in this title
        const audio_attr_t& a = mat->vts_audio_attr[i];
        int n = (pgc->audio_control[i] >> 8) & 0x07;
        AudioTrack t;
        t.number = i;
        t.channels = a.channels + 1;
        t.sampleRate = a.sample_frequency == 1 ? 96000 : 48000;
        t.language = a.lang_type == 1 ? language(a.lang_code) : "";
        t.purpose = audioPurpose(a.code_extension);
        switch (a.audio_format) {
        case 0: t.codec = AudioCodec::ac3; t.streamId = 0x80 + n; break;
        case 2:
        case 3: t.codec = AudioCodec::mpeg; t.streamId = 0xC0 + n; break;
        case 4:
            t.codec = AudioCodec::lpcm;
            t.streamId = 0xA0 + n;
            t.bitsPerSample = a.quantization == 0 ? 16 : a.quantization == 1 ? 20 : 24;
            break;
        case 6: t.codec = AudioCodec::dts; t.streamId = 0x88 + n; break;
        default: t.codec = AudioCodec::unknown; break;
        }
        title.audio.push_back(t);
    }

    // subp_control packs the physical stream for each display mode:
    // bits 24–28 4:3, 16–20 wide, 8–12 letterbox, 0–4 pan & scan.
    int shift = title.aspect == AspectRatio::fourByThree ? 24 : 16;
    for (int i = 0; i < mat->nr_of_vts_subp_streams && i < 32; ++i) {
        if (!(pgc->subp_control[i] & 0x80000000u)) continue;
        const subp_attr_t& s = mat->vts_subp_attr[i];
        SubtitleTrack t;
        t.number = i;
        t.streamId = 0x20 + static_cast<int>((pgc->subp_control[i] >> shift) & 0x1f);
        t.language = s.type == 1 ? language(s.lang_code) : "";
        t.purpose = subtitlePurpose(s.code_extension);
        title.subtitles.push_back(t);
    }

    title.palette.assign(pgc->palette, pgc->palette + 16);
}

/// Builds the chapter and cell lists by walking the title's PTTs. Walking PTTs
/// (rather than a single PGC) also handles titles split across several PGCs.
bool fillChapters(Title& title, ifo_handle_t* vts, int ttn, std::vector<std::string>& log) {
    vts_ptt_srpt_t* ptts = vts->vts_ptt_srpt;
    if (!ptts || ttn < 1 || ttn > ptts->nr_of_srpts) return false;
    const ttu_t& ttu = ptts->title[ttn - 1];

    uint64_t clock = 0;
    for (int j = 0; j < ttu.nr_of_ptts; ++j) {
        const ptt_info_t& ptt = ttu.ptt[j];
        pgc_t* pgc = pgcAt(vts, ptt.pgcn);
        if (!pgc || !pgc->program_map || !pgc->cell_playback || ptt.pgn < 1 ||
            ptt.pgn > pgc->nr_of_programs) {
            log.push_back("title " + std::to_string(title.number) + ": skipping invalid chapter " +
                          std::to_string(j + 1));
            continue;
        }
        if (title.chapters.empty()) fillStreams(title, vts, pgc);

        int firstCell = pgc->program_map[ptt.pgn - 1];
        int lastCell = ptt.pgn < pgc->nr_of_programs ? pgc->program_map[ptt.pgn] - 1
                                                      : pgc->nr_of_cells;
        Chapter chapter{.number = static_cast<int>(title.chapters.size()) + 1, .startTicks = clock};
        for (int c = firstCell; c <= lastCell && c <= pgc->nr_of_cells; ++c) {
            if (c < 1) continue;
            const cell_playback_t& cell = pgc->cell_playback[c - 1];
            // In an angle block, cells for angles 1..N follow each other; keep angle 1.
            if (cell.block_type == BLOCK_TYPE_ANGLE_BLOCK && cell.block_mode != BLOCK_MODE_FIRST_CELL)
                continue;
            if (cell.last_sector < cell.first_sector) continue;
            uint64_t ticks = ticksFromDvdTime(cell.playback_time);
            title.cells.push_back({.firstSector = cell.first_sector,
                                   .lastSector = cell.last_sector,
                                   .durationTicks = ticks,
                                   .chapter = chapter.number});
            title.sectorCount += cell.last_sector - cell.first_sector + 1ULL;
            chapter.durationTicks += ticks;
        }
        clock += chapter.durationTicks;
        title.chapters.push_back(chapter);
    }
    title.durationTicks = clock;
    return !title.cells.empty();
}

} // namespace

// MARK: - Public API

void classifyTitles(TitleList& titles) {
    std::map<std::vector<std::pair<uint32_t, uint32_t>>, int> seen;  // cell signature → first title
    Title* main = nullptr;
    for (Title& t : titles) {
        t.isMainFeature = false;
        std::vector<std::pair<uint32_t, uint32_t>> signature;
        signature.reserve(t.cells.size() + 1);
        signature.emplace_back(static_cast<uint32_t>(t.titleSet), 0);
        for (const CellRange& c : t.cells) signature.emplace_back(c.firstSector, c.lastSector);
        t.duplicatesEarlierTitle = !seen.emplace(std::move(signature), t.number).second;
        if (!t.duplicatesEarlierTitle && (!main || t.durationTicks > main->durationTicks)) main = &t;
    }
    if (main) main->isMainFeature = true;
}

DvdPtr openDvd(const std::string& path, LogSink& sink) {
    static const dvd_logger_cb logger{logCallback};
    return DvdPtr(DVDOpen2(&sink, &logger, path.c_str()));
}

DiscInfo readDiscInfo(const std::string& path) {
    LogSink sink;
    DvdPtr dvd = openDvd(path, sink);
    if (!dvd) {
        DiscInfo info;
        info.error = "Could not open " + path + " as a DVD.";
        info.log = std::move(sink.lines);
        return info;
    }
    return readDiscInfo(dvd.get(), sink);
}

DiscInfo readDiscInfo(dvd_reader_t* dvd, LogSink& sink) {
    DiscInfo info;

    char volid[33] = {};
    unsigned char volsetid[128] = {};
    if (DVDUDFVolumeInfo(dvd, volid, sizeof volid, volsetid, sizeof volsetid) != 0)
        DVDISOVolumeInfo(dvd, volid, sizeof volid, volsetid, sizeof volsetid);
    info.volumeLabel = volid;
    while (!info.volumeLabel.empty() && info.volumeLabel.back() == ' ') info.volumeLabel.pop_back();

    unsigned char discId[16];
    if (DVDDiscID(dvd, discId) == 0) info.discId = hex(discId, sizeof discId);

    IfoPtr vmg(ifoOpen(dvd, 0));
    if (!vmg || !vmg->tt_srpt) {
        info.error = "The disc's VIDEO_TS.IFO is missing or unreadable.";
        info.log = sink.lines;
        return info;
    }

    std::map<int, IfoPtr> titleSets;
    const tt_srpt_t* tt = vmg->tt_srpt;
    for (int i = 0; i < tt->nr_of_srpts; ++i) {
        const title_info_t& ti = tt->title[i];
        auto [it, inserted] = titleSets.try_emplace(ti.title_set_nr);
        if (inserted) it->second.reset(ifoOpen(dvd, ti.title_set_nr));
        ifo_handle_t* vts = it->second.get();
        if (!vts || !vts->vtsi_mat) {
            sink.lines.push_back("title " + std::to_string(i + 1) + ": VTS " +
                                 std::to_string(ti.title_set_nr) + " is unreadable");
            continue;
        }

        Title title;
        title.number = i + 1;
        title.titleSet = ti.title_set_nr;
        title.angles = ti.nr_of_angles ? ti.nr_of_angles : 1;
        if (fillChapters(title, vts, ti.vts_ttn, sink.lines)) info.titles.push_back(std::move(title));
    }

    classifyTitles(info.titles);
    info.ok = true;
    info.log = sink.lines;
    return info;
}

} // namespace dc
