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
    static let outputFolder = "outputFolder"
    static let keepStaging = "keepStaging"

    static var defaultOutputFolder: URL {
        FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask)[0].appending(path: "dvdForge")
    }
}

/// Everything a rip needs, captured when it starts.
struct RipPlan: Sendable {
    var discPath: String
    var discID: String
    var movieTitle: String
    var driveModel: String
    var outputFolder: URL
    var verify: VerifyRead
    var retries: Int
    var keepStaging: Bool
    var tracks: [Int: AppModel.TrackSelection]
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

/// DiscCore's description of a title, carried from the read to the remux.
/// Immutable once created, so sharing it across threads is safe.
final class TitleBox: @unchecked Sendable {
    let value: dc.Title
    init(_ value: dc.Title) { self.value = value }
}

struct TitleReadResult: Sendable {
    var title: TitleBox
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

struct TitleRemuxResult: Sendable {
    var completed: Bool
    var cancelled: Bool
    var error: String?
    var outputURL: URL?
    var discontinuities: Int
    var warnings: [String]
}

/// Owns a DiscCore RemuxJob; same threading contract as ReadJobHandle.
final class RemuxJobHandle: @unchecked Sendable {
    private let job: OpaquePointer

    init(read: TitleReadResult, output: URL, selection: AppModel.TrackSelection?, plan: RipPlan) {
        var request = dc.RemuxRequest()
        request.stagingPath = std.string(read.stagingURL?.path ?? "")
        request.outputPath = std.string(output.path)
        request.title = read.title.value
        // Keep the disc's own track order.
        for track in read.title.value.audio where selection?.audio.contains(Int(track.number)) ?? true {
            request.audioTracks.push_back(track.number)
        }
        for track in read.title.value.subtitles where selection?.subtitles.contains(Int(track.number)) ?? true {
            request.subtitleTracks.push_back(track.number)
        }
        request.movieTitle = std.string(plan.movieTitle)
        request.discId = std.string(plan.discID)
        request.driveModel = std.string(plan.driveModel)
        request.badSectors = read.bad
        request.unstableSectors = read.unstable
        job = dc.createRemuxJob(request)
    }

    deinit { dc.destroyRemuxJob(job) }

    func run() async -> TitleRemuxResult {
        await withCheckedContinuation { continuation in
            let thread = Thread { [self] in
                let r = dc.runRemuxJob(job)
                let error = String(r.error)
                let path = String(r.outputPath)
                continuation.resume(returning: TitleRemuxResult(
                    completed: r.completed, cancelled: r.cancelled, error: error.isEmpty ? nil : error,
                    outputURL: path.isEmpty ? nil : URL(filePath: path),
                    discontinuities: Int(r.timestampDiscontinuities), warnings: r.warnings.map { String($0) }))
            }
            thread.name = "dvdForge.remux"
            thread.qualityOfService = .userInitiated
            thread.start()
        }
    }

    func cancel() { dc.cancelRemuxJob(job) }
    func fraction() -> Double { dc.remuxJobProgress(job).fraction }
}

/// Reads and remuxes the selected titles one after another, publishing
/// progress for the UI.
@MainActor @Observable
final class RipSession {
    enum TitleStatus {
        case queued
        case reading
        case remuxing(Double)
        case finished(TitleReadResult, TitleRemuxResult)
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

    @ObservationIgnored private var currentRead: ReadJobHandle?
    @ObservationIgnored private var currentRemux: RemuxJobHandle?
    @ObservationIgnored private var stopRequested = false

    init(titles: [DiscTitle], discID: String) {
        entries = titles.map { Entry(title: $0) }
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        stagingDir = caches.appending(path: Bundle.main.bundleIdentifier ?? "dvdForge")
            .appending(path: discID.isEmpty ? "unknown-disc" : discID)
    }

    func start(_ plan: RipPlan) async {
        isRunning = true
        stopRequested = false
        defer {
            isRunning = false
            currentRead = nil
            currentRemux = nil
        }

        for index in entries.indices {
            guard !stopRequested else {
                entries[index].status = .cancelled
                continue
            }
            let title = entries[index].title
            guard let read = await read(index, plan: plan) else { continue }

            let output = outputURL(for: title, plan: plan)
            let remux = RemuxJobHandle(read: read, output: output, selection: plan.tracks[title.number], plan: plan)
            currentRemux = remux
            entries[index].status = .remuxing(0)
            let poller = Task { [weak self] in
                while !Task.isCancelled {
                    self?.entries[index].status = .remuxing(remux.fraction())
                    try? await Task.sleep(for: .milliseconds(250))
                }
            }
            let result = await remux.run()
            poller.cancel()
            currentRemux = nil

            if let error = result.error {
                entries[index].status = .failed(error)
            } else if result.cancelled {
                entries[index].status = .cancelled
            } else {
                entries[index].status = .finished(read, result)
                if !plan.keepStaging, let staging = read.stagingURL { removeStaging(staging) }
            }
        }
    }

    func cancel() {
        stopRequested = true
        currentRead?.cancel()
        currentRemux?.cancel()
    }

    /// Runs the multi-pass read; nil if it failed or was cancelled.
    private func read(_ index: Int, plan: RipPlan) async -> TitleReadResult? {
        let job = ReadJobHandle(discPath: plan.discPath, title: entries[index].title.number,
                                stagingDir: stagingDir, verify: plan.verify, retries: plan.retries)
        currentRead = job
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
        currentRead = nil

        if let error = result.error {
            entries[index].status = .failed(error)
            return nil
        }
        if result.cancelled {
            entries[index].status = .cancelled
            return nil
        }
        return result
    }

    /// <output>/<Movie>/<Movie>.mkv for the main feature, "<Movie> - tNN.mkv"
    /// otherwise; never overwrites an existing file.
    private func outputURL(for title: DiscTitle, plan: RipPlan) -> URL {
        let name = plan.movieTitle.sanitizedFileName
        let folder = plan.outputFolder.appending(path: name, directoryHint: .isDirectory)
        let base = title.isMainFeature ? name : "\(name) - t\(String(format: "%02d", title.number))"
        var url = folder.appending(path: "\(base).mkv")
        var n = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = folder.appending(path: "\(base) (\(n)).mkv")
            n += 1
        }
        return url
    }

    private func removeStaging(_ staging: URL) {
        let fm = FileManager.default
        try? fm.removeItem(at: staging)
        try? fm.removeItem(at: staging.deletingPathExtension().appendingPathExtension("map"))
        let folder = staging.deletingLastPathComponent()
        if (try? fm.contentsOfDirectory(atPath: folder.path))?.isEmpty == true { try? fm.removeItem(at: folder) }
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
        title = TitleBox(r.title)
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

extension String {
    /// Safe as a file or folder name on macOS (no "/" or ":"), never empty.
    var sanitizedFileName: String {
        let cleaned = replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: ".")))
        return cleaned.isEmpty ? "Untitled Disc" : cleaned
    }

    /// "STAR_WARS_EP4" → "Star Wars Ep4": DVD volume labels are shouty and underscored.
    var prettifiedVolumeLabel: String {
        replacingOccurrences(of: "_", with: " ")
            .split(separator: " ")
            .map { $0.prefix(1).uppercased() + $0.dropFirst().lowercased() }
            .joined(separator: " ")
    }
}
