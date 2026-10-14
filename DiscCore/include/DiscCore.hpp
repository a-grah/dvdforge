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

} // namespace dc
