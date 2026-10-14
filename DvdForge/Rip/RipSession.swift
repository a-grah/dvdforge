import DiscCore
import Foundation
import Observation

/// User-facing read settings (stored in UserDefaults via @AppStorage).
enum VerifyRead: String, CaseIterable, Identifiable, Sendable {
    case off, auto, always
    var id: Self { self }

    var label: String {
        switch self {
        case .off: "Off"
        case .auto: "Auto (only after read errors)"
        case .always: "Always"
        }
    }

    var core: dc.VerifyMode {
        switch self {
        case .off: .off
        case .auto: .automatic
        case .always: .always
        }
    }
}

enum SettingsKey {
    static let verifyRead = "verifyRead"
    static let retries = "readRetries"
}

/// Swift copies of DiscCore's read types, safe to pass between threads.
struct ReadSnapshot: Sendable {
    enum Pass: Sendable { case opening, sweep, scrape, verify, done }
    var pass: Pass = .opening
    var passDone: UInt64 = 0
    var passTotal: UInt64 = 0
    var totalSectors: UInt64 = 0
    var good: UInt64 = 0
    var bad: UInt64 = 0
    var pending: UInt64 = 0
    var unstable: UInt64 = 0
    var repaired: UInt64 = 0
    var readErrors: UInt64 = 0
    var bytesPerSecond: Double = 0

    var passFraction: Double { passTotal == 0 ? 0 : Double(passDone) / Double(passTotal) }
}

enum MapCell: UInt8, Sendable { case untried, good, pending, bad, unstable }

struct DamagedRange: Sendable, Hashable {
    var firstSector: UInt64
    var sectorCount: UInt64
    var isUnstable: Bool
    var start: Duration
    var chapter: Int
}

struct TitleReadResult: Sendable {
    var completed: Bool
    var cancelled: Bool
    var error: String?
    var stagingURL: URL?
    var totalSectors: UInt64
    var bad: UInt64
    var unstable: UInt64
    var repaired: UInt64
    var readErrors: UInt64
    var verifyRan: Bool
    var resumed: Bool
    var damage: [DamagedRange]
}

/// Owns a DiscCore ReadJob. DiscCore guarantees progress/summary/cancel are
/// thread-safe while `run` executes on another thread.
final class ReadJobHandle: @unchecked Sendable {
    private let job: OpaquePointer

    init(discPath: String, title: Int, stagingDir: URL, verify: VerifyRead, retries: Int) {
        var options = dc.ReadOptions()
        options.verify = verify.core
        options.retries = Int32(retries)
        job = dc.createReadJob(std.string(discPath), Int32(title), std.string(stagingDir.path), options)
    }

    deinit { dc.destroyReadJob(job) }

    /// Blocks until the read finishes; runs on its own thread so it never ties
    /// up Swift's cooperative pool for the (possibly hours-long) read.
    func run() async -> TitleReadResult {
        await withCheckedContinuation { continuation in
            let thread = Thread { [self] in
                continuation.resume(returning: TitleReadResult(dc.runReadJob(job)))
            }
            thread.name = "dvdForge.read"
            thread.qualityOfService = .userInitiated
            thread.start()
        }
    }

    func cancel() { dc.cancelReadJob(job) }

    func progress() -> ReadSnapshot { ReadSnapshot(dc.readJobProgress(job)) }

    func map(buckets: Int) -> [MapCell] {
        dc.readJobMapSummary(job, Int32(buckets)).map { MapCell(rawValue: $0.rawValue) ?? .untried }
    }
}

/// Reads the selected titles one after another, publishing progress for the UI.
@MainActor @Observable
final class RipSession {
    enum TitleStatus {
        case queued
        case reading
        case finished(TitleReadResult)
        case failed(String)
        case cancelled
    }

    struct Entry: Identifiable {
        let title: DiscTitle
        var status: TitleStatus = .queued
        var progress = ReadSnapshot()
        var map: [MapCell] = []
        var id: Int { title.number }
    }

    static let mapBuckets = 1200

    private(set) var entries: [Entry]
    private(set) var isRunning = false
    let stagingDir: URL

    @ObservationIgnored private var current: ReadJobHandle?
    @ObservationIgnored private var stopRequested = false

    init(titles: [DiscTitle], discID: String) {
        entries = titles.map { Entry(title: $0) }
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        stagingDir = caches.appending(path: Bundle.main.bundleIdentifier ?? "dvdForge")
            .appending(path: discID.isEmpty ? "unknown-disc" : discID)
    }

    func start(discPath: String, verify: VerifyRead, retries: Int) async {
        isRunning = true
        stopRequested = false
        defer { isRunning = false; current = nil }

        for index in entries.indices {
            guard !stopRequested else {
                entries[index].status = .cancelled
                continue
            }
            let job = ReadJobHandle(discPath: discPath, title: entries[index].title.number,
                                    stagingDir: stagingDir, verify: verify, retries: retries)
            current = job
            entries[index].status = .reading

            let poller = Task { [weak self] in
                while !Task.isCancelled {
                    self?.refresh(index, from: job)
                    try? await Task.sleep(for: .milliseconds(250))
                }
            }
            let result = await job.run()
            poller.cancel()
            refresh(index, from: job)

            entries[index].status = if let error = result.error {
                .failed(error)
            } else if result.cancelled {
                .cancelled
            } else {
                .finished(result)
            }
        }
    }

    func cancel() {
        stopRequested = true
        current?.cancel()
    }

    private func refresh(_ index: Int, from job: ReadJobHandle) {
        entries[index].progress = job.progress()
        entries[index].map = job.map(buckets: Self.mapBuckets)
    }
}

// MARK: - Bridging

extension ReadSnapshot {
    init(_ p: dc.ReadProgress) {
        pass = switch p.pass {
        case .opening: .opening
        case .sweep: .sweep
        case .scrape: .scrape
        case .verify: .verify
        default: .done
        }
        passDone = p.passDone
        passTotal = p.passTotal
        totalSectors = p.totalSectors
        good = p.good
        bad = p.bad
        pending = p.pending
        unstable = p.unstable
        repaired = p.repaired
        readErrors = p.readErrors
        bytesPerSecond = p.bytesPerSecond
    }
}

extension TitleReadResult {
    init(_ r: dc.ReadResult) {
        completed = r.completed
        cancelled = r.cancelled
        let message = String(r.error)
        error = message.isEmpty ? nil : message
        let path = String(r.stagingPath)
        stagingURL = path.isEmpty ? nil : URL(filePath: path)
        totalSectors = r.totalSectors
        bad = r.bad
        unstable = r.unstable
        repaired = r.repaired
        readErrors = r.readErrors
        verifyRan = r.verifyRan
        resumed = r.resumed
        damage = r.damage.map {
            DamagedRange(firstSector: $0.firstSector, sectorCount: $0.sectorCount,
                         isUnstable: $0.state == .unstable,
                         start: .nanoseconds(Int64($0.startTicks) * 100_000 / 9), chapter: Int($0.chapter))
        }
    }
}
