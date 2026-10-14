#include "SectorSource.hpp"

#include <fcntl.h>
#include <sys/ioctl.h>
#include <unistd.h>

#include <IOKit/storage/IODVDMediaBSDClient.h>
#include <dvdread/dvd_reader.h>

#include <chrono>
#include <thread>

namespace dc {

// MARK: - DvdSectorSource

DvdSectorSource::DvdSectorSource(dvd_reader_t* dvd, int titleSet, std::string devicePath)
    : file_(DVDOpenFile(dvd, titleSet, DVD_READ_TITLE_VOBS)), devicePath_(std::move(devicePath)) {}

DvdSectorSource::~DvdSectorSource() {
    if (slow_) setSlow(false);
    if (file_) DVDCloseFile(file_);
}

bool DvdSectorSource::read(uint32_t lba, uint32_t count, uint8_t* buf) {
    if (!file_) return false;
    return DVDReadBlocks(file_, static_cast<int>(lba), count, buf) == static_cast<ssize_t>(count);
}

bool DvdSectorSource::deviceGone() const {
    // Only meaningful for raw devices; image files and folders don't vanish.
    return devicePath_.rfind("/dev/", 0) == 0 && access(devicePath_.c_str(), F_OK) != 0;
}

void DvdSectorSource::setSlow(bool slow) {
    if (slow == slow_ || devicePath_.rfind("/dev/", 0) != 0) return;
    // A second descriptor just for the ioctl; libdvdcss owns the reading one.
    int fd = open(devicePath_.c_str(), O_RDONLY | O_NONBLOCK);
    if (fd < 0) return;
    uint16_t speed = slow ? kDVDSpeedMin : kDVDSpeedMax;
    if (ioctl(fd, DKIOCDVDSETSPEED, &speed) == 0) slow_ = slow;
    close(fd);
}

// MARK: - FaultySectorSource

FaultySectorSource::FaultySectorSource(std::unique_ptr<SectorSource> inner, const FaultPlan& plan)
    : inner_(std::move(inner)), plan_(plan), slow_(plan.slow.begin(), plan.slow.end()),
      hardBad_(plan.hardBad.begin(), plan.hardBad.end()),
      flipPending_(plan.flipped.begin(), plan.flipped.end()) {
    for (uint32_t s : plan.intermittent) intermittentLeft_[s] = plan.intermittentFailures;
}

bool FaultySectorSource::read(uint32_t lba, uint32_t count, uint8_t* buf) {
    using std::chrono::milliseconds;
    if (vanished_) return false;
    if (plan_.vanishAtSector >= lba && plan_.vanishAtSector < int64_t(lba) + count) {
        vanished_ = true;
        return false;
    }
    bool failed = false, slow = false;
    for (uint32_t s = lba; s < lba + count; ++s) {
        if (slow_.count(s)) slow = true;
        if (hardBad_.count(s)) failed = true;
        if (auto it = intermittentLeft_.find(s); it != intermittentLeft_.end() && it->second > 0) {
            --it->second;
            failed = true;
        }
    }
    if (failed) {
        if (plan_.failureDelayMs) std::this_thread::sleep_for(milliseconds(plan_.failureDelayMs));
        return false;
    }
    if (slow) std::this_thread::sleep_for(milliseconds(plan_.slowDelayMs));
    if (!inner_->read(lba, count, buf)) return false;
    // Silent corruption: the first successful read of these sectors returns garbage.
    for (uint32_t s = lba; s < lba + count; ++s) {
        if (flipPending_.erase(s)) {
            uint8_t* sector = buf + static_cast<size_t>(s - lba) * kSectorSize;
            for (uint32_t i = 100; i < 200; ++i) sector[i] ^= 0x5a;
        }
    }
    return true;
}

} // namespace dc
