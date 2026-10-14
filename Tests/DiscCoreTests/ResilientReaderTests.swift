import DiscCore
import Foundation
import Testing

/// Drives the multi-pass reader against the fixture ISO, with simulated media
/// faults injected under it.
@Suite(.serialized) struct ResilientReaderTests {
    let fixture = DiscInfoTests.fixture
    let mainTitle: Int32 = 1
    /// VTS-relative sector where title 1's data starts, and its size in sectors.
    let base: UInt32
    let firstCellSectors: UInt32
    let totalSectors: UInt64
    let reference: Data

    init() throws {
        let info = dc.readDiscInfo(std.string(fixture))
        try #require(info.ok)
        let title = info.titles[0]
        base = title.cells[0].firstSector
        firstCellSectors = title.cells[0].lastSector - title.cells[0].firstSector + 1
        totalSectors = title.sectorCount

        // A clean read is the reference everything else is compared with.
        let (result, data) = Self.read(fixture, title: mainTitle, verify: .off)
        try #require(result.completed && result.bad == 0)
        reference = data
    }

    // MARK: Helpers

    static func tempDir() -> URL {
        FileManager.default.temporaryDirectory.appending(path: "dvdforge-tests/\(UUID().uuidString)")
    }

    @discardableResult
    static func read(_ disc: String, title: Int32, verify: dc.VerifyMode, faults: dc.FaultPlan? = nil,
                     dir: URL = tempDir()) -> (dc.ReadResult, Data) {
        var options = dc.ReadOptions()
        options.verify = verify
        options.retries = 4
        let job = if let faults {
            dc.createReadJobWithFaults(std.string(disc), title, std.string(dir.path), options, faults)
        } else {
            dc.createReadJob(std.string(disc), title, std.string(dir.path), options)
        }
        defer { dc.destroyReadJob(job) }
        let result = dc.runReadJob(job)
        let data = (try? Data(contentsOf: URL(filePath: String(result.stagingPath)))) ?? Data()
        return (result, data)
    }

    private func sector(_ data: Data, _ index: Int) -> Data {
        data.subdata(in: index * 2048 ..< (index + 1) * 2048)
    }

    private func plan(_ build: (inout dc.FaultPlan) -> Void) -> dc.FaultPlan {
        var p = dc.FaultPlan()
        build(&p)
        return p
    }

    // MARK: Tests

    @Test func cleanReadIsSinglePassAndWellFormed() {
        let (result, data) = Self.read(fixture, title: mainTitle, verify: .automatic)
        #expect(result.completed && !result.cancelled && String(result.error).isEmpty)
        #expect(result.good == totalSectors && result.bad == 0 && result.unstable == 0)
        #expect(!result.verifyRan, "Auto mode must not re-read a healthy disc")
        #expect(result.sectorsReadFromDisc == totalSectors)
        #expect(UInt64(data.count) == totalSectors * 2048)
        // Every DVD-Video sector is an MPEG-2 pack: 00 00 01 BA.
        let packStart = Data([0x00, 0x00, 0x01, 0xBA])
        let malformed = (0 ..< Int(totalSectors)).filter { data[$0 * 2048 ..< $0 * 2048 + 4] != packStart }
        #expect(malformed.isEmpty, "sectors without a pack header: \(malformed.prefix(5))")
        #expect(data == reference)
    }

    @Test func intermittentErrorsAreRecoveredByScraping() {
        let faults = plan {
            for s in [base + 100, base + 101, base + 600] { $0.intermittent.push_back(s) }
            $0.intermittentFailures = 2
        }
        let (result, data) = Self.read(fixture, title: mainTitle, verify: .automatic, faults: faults)
        #expect(result.completed && result.bad == 0 && result.unstable == 0)
        #expect(result.readErrors > 0)
        #expect(result.verifyRan, "Auto mode verifies once a read error occurred")
        #expect(result.damage.isEmpty)
        #expect(data == reference)
    }

    @Test func hardErrorsAreZeroFilledAndLocated() throws {
        try #require(firstCellSectors > 1010)
        let faults = plan { for s in base + 1000 ..< base + 1010 { $0.hardBad.push_back(s) } }
        let (result, data) = Self.read(fixture, title: mainTitle, verify: .automatic, faults: faults)
        #expect(result.completed && result.bad == 10 && result.good == totalSectors - 10)

        try #require(result.damage.count == 1)
        let damage = result.damage[0]
        #expect(damage.firstSector == 1000 && damage.sectorCount == 10 && damage.state == .bad)
        #expect(damage.chapter >= 1)

        for i in 1000 ..< 1010 { #expect(sector(data, i) == Data(count: 2048), "sector \(i) should be zeros") }
        var expected = reference
        expected.replaceSubrange(1000 * 2048 ..< 1010 * 2048, with: Data(count: 10 * 2048))
        #expect(data == expected, "everything except the bad sectors matches a clean read")
    }

    @Test func silentCorruptionIsRepairedWhenVerifyIsAlways() {
        let faults = plan { for s in [base + 50, base + 2000] { $0.flipped.push_back(s) } }
        let (result, data) = Self.read(fixture, title: mainTitle, verify: .always, faults: faults)
        #expect(result.completed && result.verifyRan)
        #expect(result.repaired == 2 && result.unstable == 0 && result.bad == 0)
        #expect(data == reference)
    }

    @Test func silentCorruptionWithoutErrorsIsNotCaughtInAutoMode() {
        // Documents the speed/safety trade-off of Auto: no read errors, no re-read.
        let faults = plan { $0.flipped.push_back(base + 50) }
        let (result, data) = Self.read(fixture, title: mainTitle, verify: .automatic, faults: faults)
        #expect(result.completed && !result.verifyRan)
        #expect(data != reference)
    }

    @Test func cancelledRipResumesWithoutRereadingGoodSectors() {
        let dir = Self.tempDir()
        let (first, _) = Self.read(fixture, title: mainTitle, verify: .off,
                                   faults: plan { $0.cancelAfterSectors = 1500 }, dir: dir)
        #expect(first.cancelled && !first.completed)
        #expect(first.good > 0 && first.good < totalSectors)

        let (second, data) = Self.read(fixture, title: mainTitle, verify: .off, dir: dir)
        #expect(second.completed && second.resumed)
        #expect(second.sectorsReadFromDisc == totalSectors - first.good)
        #expect(data == reference)
    }

    @Test func unknownTitleFails() {
        let (result, _) = Self.read(fixture, title: 99, verify: .off)
        #expect(!result.completed && String(result.error).contains("Title 99"))
    }
}
