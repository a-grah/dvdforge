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
                     dir: URL = tempDir(), configure: (inout dc.ReadOptions) -> Void = { _ in }) -> (dc.ReadResult, Data) {
        var options = dc.ReadOptions()
        options.verify = verify
        options.retries = 4
        configure(&options)
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

    @Test func largeDamagedAreaCostsFewReads() throws {
        // A 3000-sector scratch. Reading every sector with retries would be ~12000
        // failed reads, each of which can take a real drive many seconds.
        try #require(totalSectors > 4100)
        let faults = plan { for s in base + 1000 ..< base + 4000 { $0.hardBad.push_back(s) } }
        let (result, data) = Self.read(fixture, title: mainTitle, verify: .off, faults: faults)
        #expect(result.completed && result.bad == 3000, "bad = \(result.bad)")
        #expect(result.readErrors < 300, "read errors = \(result.readErrors)")
        var expected = reference
        expected.replaceSubrange(1000 * 2048 ..< 4000 * 2048, with: Data(count: 3000 * 2048))
        #expect(data == expected, "everything outside the scratch is recovered, nothing inside is invented")
        let log = result.events.map { String($0.message) }
        #expect(log.contains { $0.hasPrefix("Read error in chapter") }, "log: \(log)")
        #expect(log.contains { $0.hasPrefix("First pass done.") })
        #expect(log.contains { $0.contains("recovered") && $0.contains("from its edges") })
    }

    @Test func stuckReadIsMarkedForLaterWhileStillStuck() async throws {
        let dir = Self.tempDir()
        var faults = dc.FaultPlan()
        faults.slow.push_back(base + 100)
        faults.slowDelayMs = 1500
        var options = dc.ReadOptions()
        options.verify = .off
        options.slowReadSeconds = 0.2
        let job = dc.createReadJobWithFaults(std.string(fixture), mainTitle, std.string(dir.path), options, faults)
        defer { dc.destroyReadJob(job) }
        let box = ResultBox()
        let thread = Thread { box.result = dc.runReadJob(job) }
        thread.start()

        // While the read is stuck, the map on disk must already say "come back later",
        // so a drive reset at this point wouldn't send a resume straight back here.
        try await Task.sleep(for: .milliseconds(700))
        let map = try String(contentsOf: dir.appending(path: "title-01.map"), encoding: .utf8)
        #expect(map.split(separator: "\n").contains { $0.hasSuffix(" 2") }, "map: \(map)")
        // The UI can see what the drive is stuck on, and for how long.
        let now = dc.readJobProgress(job)
        #expect(now.currentSector >= 0 && now.currentSector <= 100 && now.currentSeconds > 0.4)
        #expect(now.damageEnd > now.damageFirst)
        #expect(dc.readJobEvents(job, 0).contains { String($0.message).hasPrefix("The drive is stuck on chapter") })

        while box.result == nil { try await Task.sleep(for: .milliseconds(50)) }
        let result = try #require(box.result)
        #expect(result.completed && result.slowReads == 1 && result.bad == 0)
        #expect(try Data(contentsOf: URL(filePath: String(result.stagingPath))) == reference)
    }

    @Test func driveLossStopsCleanlyAndResumes() {
        let dir = Self.tempDir()
        let (lost, _) = Self.read(fixture, title: mainTitle, verify: .automatic,
                                  faults: plan { $0.vanishAtSector = Int64(base + 2000) }, dir: dir)
        #expect(lost.deviceLost && lost.cancelled && !lost.completed)
        #expect(lost.bad == 0, "a vanished drive says nothing about the disc; nothing may be marked bad")
        #expect(lost.good > 1000 && lost.good <= 2000, "good = \(lost.good)")  // everything before the chunk where it vanished

        let (resumed, data) = Self.read(fixture, title: mainTitle, verify: .automatic, dir: dir)
        #expect(resumed.completed && resumed.resumed && resumed.bad == 0)
        #expect(data == reference)
    }

    @Test func areaThatHangsTheDriveIsGivenUpQuickly() {
        // Each failing read takes 600 ms here (minutes on a real drive). Retrying
        // a 400-sector core block by block would hang 25+ times; instead one slow
        // failure gives up on the whole core.
        var faults = dc.FaultPlan()
        for s in base + 1000 ..< base + 1400 { faults.hardBad.push_back(s) }
        faults.failureDelayMs = 600
        let clock = ContinuousClock()
        let start = clock.now
        let (result, _) = Self.read(fixture, title: mainTitle, verify: .off, faults: faults) {
            $0.slowReadSeconds = 0.2
        }
        #expect(result.completed && result.bad == 400, "bad = \(result.bad)")
        #expect(result.readErrors <= 10, "read errors = \(result.readErrors)")
        #expect(clock.now - start < .seconds(10))
    }

    @Test func stopRetryingFinishesWithWhatWasRead() async throws {
        let dir = Self.tempDir()
        var faults = dc.FaultPlan()
        for s in base + 1000 ..< base + 1400 { faults.hardBad.push_back(s) }
        faults.failureDelayMs = 100  // failing reads are slow, like a real drive
        var options = dc.ReadOptions()
        options.verify = .automatic
        let job = dc.createReadJobWithFaults(std.string(fixture), mainTitle, std.string(dir.path), options, faults)
        defer { dc.destroyReadJob(job) }
        let box = ResultBox()
        let thread = Thread { box.result = dc.runReadJob(job) }
        thread.start()

        while dc.readJobProgress(job).pass != .scrape, box.result == nil {
            try await Task.sleep(for: .milliseconds(5))
        }
        dc.stopRetryingReadJob(job)
        while box.result == nil { try await Task.sleep(for: .milliseconds(20)) }
        let result = try #require(box.result)
        #expect(result.completed && result.stoppedRetrying && !result.verifyRan)
        #expect(result.bad == 400)
    }

    @Test func unknownTitleFails() {
        let (result, _) = Self.read(fixture, title: 99, verify: .off)
        #expect(!result.completed && String(result.error).contains("Title 99"))
    }
}

/// Carries a result out of a Thread in tests.
final class ResultBox: @unchecked Sendable {
    var result: dc.ReadResult?
}
