// Internal: where title sectors come from. The reader only talks to this
// interface, so tests can inject media faults without hardware.
#pragma once

#include "DiscCore.hpp"

#include <cstdint>
#include <map>
#include <memory>
#include <set>
#include <string>

struct dvd_reader_s;
struct dvd_file_s;

namespace dc {

class SectorSource {
public:
    virtual ~SectorSource() = default;
    /// Reads `count` decrypted sectors starting at VTS-relative `lba`.
    /// Returns false if any of them could not be read.
    virtual bool read(uint32_t lba, uint32_t count, uint8_t* buf) = 0;
    /// Best effort: run the drive at minimum speed while scraping damage.
    virtual void setSlow(bool) {}
    /// True once the device itself is gone (drive reset or unplugged): further
    /// failures say nothing about the disc.
    virtual bool deviceGone() const { return false; }
};

/// Reads a VTS's title VOBs through libdvdread (and libdvdcss for CSS).
class DvdSectorSource final : public SectorSource {
public:
    /// `dvd` must outlive this object. `devicePath` is used for the speed
    /// ioctl when it names a /dev node; otherwise speed control is skipped.
    DvdSectorSource(dvd_reader_s* dvd, int titleSet, std::string devicePath);
    ~DvdSectorSource() override;

    bool isOpen() const { return file_ != nullptr; }
    bool read(uint32_t lba, uint32_t count, uint8_t* buf) override;
    void setSlow(bool slow) override;
    bool deviceGone() const override;

private:
    dvd_file_s* file_ = nullptr;
    std::string devicePath_;
    bool slow_ = false;
};

/// Wraps another source and simulates damaged media (see FaultPlan).
class FaultySectorSource final : public SectorSource {
public:
    FaultySectorSource(std::unique_ptr<SectorSource> inner, const FaultPlan& plan);
    bool read(uint32_t lba, uint32_t count, uint8_t* buf) override;
    bool deviceGone() const override { return vanished_; }

private:
    std::unique_ptr<SectorSource> inner_;
    FaultPlan plan_;
    std::set<uint32_t> slow_;
    bool vanished_ = false;
    std::set<uint32_t> hardBad_;
    std::map<uint32_t, int> intermittentLeft_;
    std::set<uint32_t> flipPending_;
};

} // namespace dc
