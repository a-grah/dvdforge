#include "DiscCore.hpp"

#include <dvdcss/version.h>
#include <dvdread/dvd_reader.h>

extern "C" {
#include <libavcodec/avcodec.h>
#include <libavformat/avformat.h>
}

namespace dc {

namespace {

std::string ffVersion(unsigned v) {
    return std::to_string(AV_VERSION_MAJOR(v)) + "." + std::to_string(AV_VERSION_MINOR(v)) + "." +
           std::to_string(AV_VERSION_MICRO(v));
}

} // namespace

LibraryVersions libraryVersions() {
    return {
        .libdvdread = DVDREAD_VERSION_STRING,
        .libdvdcss = DVDCSS_VERSION_STRING,
        .libavformat = ffVersion(avformat_version()),
        .libavcodec = ffVersion(avcodec_version()),
    };
}

bool canOpenDisc(const std::string& path) {
    dvd_reader_t* dvd = DVDOpen(path.c_str());
    if (!dvd) return false;
    DVDClose(dvd);
    return true;
}

} // namespace dc
