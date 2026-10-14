// DiscCore: the C++ engine behind dvdForge.
//
// This header is the only surface Swift sees. It deliberately exposes plain
// value types (std::string, std::vector, structs of integers) and never any
// libdvdread or FFmpeg types, so the Swift side stays insulated from the C APIs.
#pragma once

#include <string>

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

} // namespace dc
