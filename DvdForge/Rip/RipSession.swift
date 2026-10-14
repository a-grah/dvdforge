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
    static let preferredLanguages = "preferredLanguages"
    static let audioTracks = "audioTracks"
    static let subtitleTracks = "subtitleTracks"
    static let autoRip = "autoRipOnInsert"
    static let ejectWhenDone = "ejectWhenDone"

    static var outputFolderURL: URL {
        UserDefaults.standard.string(forKey: outputFolder).map { URL(filePath: $0) } ?? defaultOutputFolder
    }

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
    /// Finish without going back to damage (see dc::ReadOptions::skipRetries).
    var skipRetries = false
    var tracks: [Int: AppModel.TrackSelection]
    /// Per title, the audio track to flag as default (absent: the first kept).
    var defaultAudio: [Int: Int] = [:]
    /// The movie, when identified online.
    var movie: MovieMatch?
}

/// Swift copies of DiscCore's read types, safe to pass between threads.
struct ReadSnapshot: Sendable {
    enum Pass: Sendable { case opening, sweep, trim, scrape, verify, done }
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
    /// The read in flight, if any.
    var current: CurrentRead?
    /// Sectors [first, end) spanning all damage found so far.
    var damageSpan: Range<UInt64>?

    struct CurrentRead: Sendable, Equatable {
        var sector: UInt64
        var count: UInt32
        var seconds: Double
        var chapter: Int
        var position: Duration
    }

    var passFraction: Double { passTotal == 0 ? 0 : Double(passDone) / Double(passTotal) }
}

/// One line of the reader's activity log.
struct RipEvent: Sendable, Hashable, Identifiable {
    var id: Int
    var date: Date
    var message: String
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
    var deviceLost: Bool
    var stoppedRetrying: Bool
    var damage: [DamagedRange]
    var log: [String]
}

/// Moves a job pointer to the queue that destroys it.
private struct UncheckedPointer: @unchecked Sendable {
    let pointer: OpaquePointer
    init(_ pointer: OpaquePointer) { self.pointer = pointer }
}

/// Owns a DiscCore ReadJob. DiscCore guarantees progress/summary/cancel are
/// thread-safe while `run` executes on another thread.
final class ReadJobHandle: @unchecked Sendable {
    private let job: OpaquePointer

    init(discPath: String, title: Int, stagingDir: URL, verify: VerifyRead, retries: Int, skipRetries: Bool) {
        var options = dc.ReadOptions()
        options.verify = verify.core
        options.retries = Int32(retries)
        options.skipRetries = skipRetries
        // Development aid: `-simulateDamage 1000-4000@300` makes title sectors
        // 1000..<4000 (VTS-relative) unreadable, each failure taking 300 ms, to
        // exercise the damage UI without a scratched disc.
        if let spec = UserDefaults.standard.string(forKey: "simulateDamage"),
           let match = spec.wholeMatch(of: /(\d+)-(\d+)(?:@(\d+))?/),
           let first = UInt32(match.1), let end = UInt32(match.2), first < end {
            var faults = dc.FaultPlan()
            for s in first ..< end { faults.hardBad.push_back(s) }
            faults.failureDelayMs = Int32(match.3.flatMap { Int($0) } ?? 0)
            options.slowReadSeconds = 0.25
            job = dc.createReadJobWithFaults(std.string(discPath), Int32(title), std.string(stagingDir.path),
                                             options, faults)
        } else {
            job = dc.createReadJob(std.string(discPath), Int32(title), std.string(stagingDir.path), options)
        }
    }

    deinit {
        // Closing the job closes the DVD device, which can block for minutes if
        // the drive is hung on a scratch; never do that on the main thread.
        let job = UncheckedPointer(job)
        DispatchQueue.global(qos: .utility).async { dc.destroyReadJob(job.pointer) }
    }

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
    func stopRetrying() { dc.stopRetryingReadJob(job) }

    func progress() -> ReadSnapshot { ReadSnapshot(dc.readJobProgress(job)) }

    func map(buckets: Int) -> [MapCell] {
        dc.readJobMapSummary(job, Int32(buckets)).map { MapCell(rawValue: $0.rawValue) ?? .untried }
    }

    func map(_ range: Range<UInt64>, buckets: Int) -> [MapCell] {
        dc.readJobMapRange(job, range.lowerBound, range.upperBound, Int32(buckets))
            .map { MapCell(rawValue: $0.rawValue) ?? .untried }
    }

    func events(from index: Int) -> [(seconds: Double, message: String)] {
        dc.readJobEvents(job, index).map { ($0.seconds, String($0.message)) }
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
        request.defaultAudioTrack = Int32(plan.defaultAudio[Int(read.title.value.number)] ?? -1)
        request.movieTitle = std.string(plan.movieTitle)
        request.discId = std.string(plan.discID)
        request.driveModel = std.string(plan.driveModel)
        if let movie = plan.movie { request.tmdb = std.string("movie/\(movie.id)") }
        request.badSectors = read.bad
        request.unstableSectors = read.unstable
        job = dc.createRemuxJob(request)
    }

    deinit {
        let job = UncheckedPointer(job)
        DispatchQueue.global(qos: .utility).async { dc.destroyRemuxJob(job.pointer) }
    }

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
        /// Zoomed map around the damage, and the sectors it covers.
        var closeUp: [MapCell] = []
        var closeUpRange: Range<UInt64>?
        var events: [RipEvent] = []
        var started = Date()
        var reportError: String?
        var id: Int { title.number }
    }

    static let mapBuckets = 1200

    private(set) var entries: [Entry]
    private(set) var isRunning = false
    /// Why the rip stopped early, when it wasn't the user (e.g. the disc was removed).
    var notice: String?
    /// Something worth knowing about how this rip is running (not an interruption).
    var info: String?
    /// The drive vanished mid-read (reset or unplugged); the rip can resume.
    private(set) var deviceLost = false

    var allFinished: Bool {
        entries.allSatisfy { if case .finished = $0.status { true } else { false } }
    }
    let stagingDir: URL

    @ObservationIgnored private var currentRead: ReadJobHandle?
    @ObservationIgnored private var currentRemux: RemuxJobHandle?
    @ObservationIgnored private var stopRequested = false

    init(titles: [DiscTitle], discID: String) {
        entries = titles.map { Entry(title: $0) }
        stagingDir = Self.stagingDir(discID: discID)
    }

    nonisolated static func stagingDir(discID: String) -> URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appending(path: Bundle.main.bundleIdentifier ?? "dvdForge")
            .appending(path: discID.isEmpty ? "unknown-disc" : discID)
    }

    /// True while a title is in the trim or scrape pass (working on damage).
    var isWorkingOnDamage: Bool {
        entries.contains {
            if case .reading = $0.status { $0.progress.pass == .trim || $0.progress.pass == .scrape } else { false }
        }
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
                if let mkv = result.outputURL {
                    let report = RipReport(plan: plan, title: title, read: read, remux: result, mkv: mkv,
                                           selection: plan.tracks[title.number])
                    do {
                        try report.write(to: RipReport.url(forMKV: mkv))
                    } catch {
                        entries[index].reportError = "Couldn't save the rip report: \(error.localizedDescription)"
                    }
                }
                if !plan.keepStaging, let staging = read.stagingURL { removeStaging(staging) }
            }
        }
    }

    func cancel() {
        stopRequested = true
        currentRead?.cancel()
        currentRemux?.cancel()
    }

    /// Finish the current title with whatever has been read so far.
    func stopRetrying() {
        currentRead?.stopRetrying()
    }

    /// Runs the multi-pass read; nil if it failed or was cancelled.
    private func read(_ index: Int, plan: RipPlan) async -> TitleReadResult? {
        let job = ReadJobHandle(discPath: plan.discPath, title: entries[index].title.number,
                                stagingDir: stagingDir, verify: plan.verify, retries: plan.retries,
                                skipRetries: plan.skipRetries)
        currentRead = job
        entries[index].status = .reading
        entries[index].started = Date()
        entries[index].events = []
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
            if result.deviceLost {
                deviceLost = true
                stopRequested = true
            }
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

    static let closeUpBuckets = 300

    private func refresh(_ index: Int, from job: ReadJobHandle) {
        let progress = job.progress()
        entries[index].progress = progress
        entries[index].map = job.map(buckets: Self.mapBuckets)
        if let span = progress.damageSpan {
            // A margin either side so the edges of the damage are visible.
            let margin = max(256, UInt64(span.count) / 3)
            let window = span.lowerBound.saturatingSubtract(margin) ..< min(progress.totalSectors, span.upperBound + margin)
            entries[index].closeUpRange = window
            entries[index].closeUp = job.map(window, buckets: Self.closeUpBuckets)
        }
        let start = entries[index].started
        let new = job.events(from: entries[index].events.count)
        for event in new {
            entries[index].events.append(RipEvent(id: entries[index].events.count,
                                                  date: start.addingTimeInterval(event.seconds), message: event.message))
        }
    }
}

// MARK: - Bridging

extension ReadSnapshot {
    init(_ p: dc.ReadProgress) {
        pass = switch p.pass {
        case .opening: .opening
        case .sweep: .sweep
        case .trim: .trim
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
        if p.currentSector >= 0 {
            current = CurrentRead(sector: UInt64(p.currentSector), count: p.currentCount, seconds: p.currentSeconds,
                                  chapter: Int(p.currentChapter),
                                  position: .nanoseconds(Int64(p.currentTicks) * 100_000 / 9))
        }
        if p.damageEnd > p.damageFirst { damageSpan = p.damageFirst ..< p.damageEnd }
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
        deviceLost = r.deviceLost
        stoppedRetrying = r.stoppedRetrying
        log = r.events.map { String(format: "+%@  %@", Duration.seconds($0.seconds).dvdFormatted, String($0.message)) }
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

extension UInt64 {
    func saturatingSubtract(_ other: UInt64) -> UInt64 { self > other ? self - other : 0 }
}

/// What an earlier, unfinished rip of a title left behind (see dc::stagedRead).
struct UnfinishedRip: Sendable, Equatable {
    var total: UInt64
    var good: UInt64
    var damaged: UInt64  // pending + bad + unstable

    var fractionRead: Double { total == 0 ? 0 : Double(good) / Double(total) }
    var damagedDescription: String { (Int64(damaged) * 2048).formatted(.byteCount(style: .file)) }

    static func check(discID: String, title: Int) -> UnfinishedRip? {
        let r = dc.stagedRead(std.string(RipSession.stagingDir(discID: discID).path), Int32(title))
        guard r.exists, r.good < r.totalSectors else { return nil }
        return UnfinishedRip(total: r.totalSectors, good: r.good, damaged: r.pending + r.bad + r.unstable)
    }
}
