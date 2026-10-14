// Internal helpers shared between DiscCore translation units.
#pragma once

#include "DiscCore.hpp"

#include <memory>
#include <string>
#include <vector>

#include <dvdread/dvd_reader.h>

namespace dc {

/// Collects libdvdread warnings and errors. Must outlive the dvd_reader_t it
/// was passed to.
struct LogSink {
    std::vector<std::string> lines;
};

struct DvdCloser {
    void operator()(dvd_reader_t* d) const { DVDClose(d); }
};
using DvdPtr = std::unique_ptr<dvd_reader_t, DvdCloser>;

/// DVDOpen with logging routed into `sink`.
DvdPtr openDvd(const std::string& path, LogSink& sink);

/// readDiscInfo on an already open disc; log lines are appended to `sink`.
DiscInfo readDiscInfo(dvd_reader_t* dvd, LogSink& sink);

} // namespace dc
