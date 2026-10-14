import AppKit
import Foundation
import Observation

/// Top-level app state: which disc is being looked at, its structure, and
/// what the user has selected to rip.
@MainActor @Observable
final class AppModel {
    enum Source: Hashable {
        case drive(OpticalDisc)
        case file(URL)

        var path: String {
            switch self {
            case let .drive(disc): disc.devicePath
            case let .file(url): url.path
            }
        }

        var displayName: String {
            switch self {
            case let .drive(disc): disc.volumeName ?? disc.bsdName
            case let .file(url): url.lastPathComponent
            }
        }
    }

    enum State {
        case idle
        case scanning
        case loaded(Disc)
        case failed(String, log: [String])
    }

    /// Which tracks of one title will be ripped.
    struct TrackSelection: Hashable {
        var audio: Set<Int>
        var subtitles: Set<Int>
    }

    /// What the disc is, according to TMDb.
    enum Identification: Equatable {
        case notConfigured
        case looking
        case identified(MovieMatch)
        case choose([MovieMatch], query: String)
        case unmatched(query: String)
        case failed(String)
    }

    let drives = DriveMonitor()
    private(set) var source: Source?
    private(set) var state: State = .idle
    private(set) var rip: RipSession?
    private(set) var identification: Identification = .notConfigured
    var isChoosingMovie = false

    var selectedTitles: Set<Int> = []
    var isImporting = false
    /// Shown as an alert, e.g. not enough disk space to start a rip.
    var alert: String?
    var trackSelections: [Int: TrackSelection] = [:]

    @ObservationIgnored private var scanTask: Task<Void, Never>?
    @ObservationIgnored private var lookupTask: Task<Void, Never>?
    @ObservationIgnored private var autoRipAfterLookup = false

    var isDriveSource: Bool {
        if case .drive = source { true } else { false }
    }

    var disc: Disc? {
        if case let .loaded(disc) = state { disc } else { nil }
    }

    func start() {
        drives.start()
        // Development convenience: `dvdForge -open /path/to/disc.iso`.
        if let path = UserDefaults.standard.string(forKey: "open") {
            open(.file(URL(filePath: path)))
        }
    }

    /// Called when the set of discs in drives changes.
    func drivesChanged() {
        if case let .drive(current) = source {
            guard let now = drives.discs.first(where: { $0.bsdName == current.bsdName }) else {
                if isRipping, let rip {
                    // Pulled out mid-rip: stop at once rather than retrying a missing disc.
                    // Keep the panel up so the user sees what happened.
                    rip.notice = "The disc was removed. Insert it again and rip to resume where it left off; sectors already read are kept."
                    rip.cancel()
                    source = nil
                } else {
                    close()
                }
                return
            }
            source = .drive(now)  // pick up the volume name once mounted
        }
        // A newly inserted disc takes over unless the user is browsing a file or ripping.
        if source == nil, !isRipping, let disc = drives.discs.first {
            open(.drive(disc))
        }
    }

    func open(_ source: Source) {
        scanTask?.cancel()
        lookupTask?.cancel()
        identification = .notConfigured
        autoRipAfterLookup = false
        endRip()
        self.source = source
        state = .scanning
        selectedTitles = []
        trackSelections = [:]
        scanTask = Task {
            do {
                let disc = try await DiscReader.read(path: source.path)
                guard !Task.isCancelled else { return }
                load(disc)
            } catch {
                guard !Task.isCancelled else { return }
                let log = if case let DiscReadError.unreadable(_, log) = error { log } else { [String]() }
                var message = error.localizedDescription
                if case .drive = source {
                    message = "dvdForge couldn't read this disc's structure. If it is a commercial DVD, the drive may be set to a different region than the disc, or the start of the disc (where its menus and index live) may be damaged. Cleaning the disc or trying another drive can help.\n\n\(message)"
                }
                state = .failed(message, log: log)
            }
        }
    }

    func rescan() {
        if let source { open(source) }
    }

    func close() {
        scanTask?.cancel()
        lookupTask?.cancel()
        identification = .notConfigured
        autoRipAfterLookup = false
        endRip()
        source = nil
        state = .idle
        selectedTitles = []
        trackSelections = [:]
    }

    func eject() {
        guard case let .drive(disc) = source else { return }
        drives.eject(disc)
    }

    // MARK: - Ripping

    var isRipping: Bool { rip?.isRunning == true }

    func startRip() {
        guard let disc, let source, !isRipping else { return }
        let titles = disc.titles.filter { selectedTitles.contains($0.number) }
        guard !titles.isEmpty else { return }
        let defaults = UserDefaults.standard
        let outputFolder = SettingsKey.outputFolderURL
        let session = RipSession(titles: titles, discID: disc.discID)
        if let problem = Self.spaceProblem(bytes: titles.reduce(0) { $0 + $1.byteCount },
                                           staging: session.stagingDir, output: outputFolder) {
            alert = problem
            return
        }
        let preferences = TrackPreferences.load(from: defaults)
        var defaultAudio: [Int: Int] = [:]
        for title in titles {
            let selected = trackSelections[title.number]?.audio ?? []
            defaultAudio[title.number] = preferences.defaultAudio(for: title, selected: selected)
        }
        let driveModel = if case let .drive(drive) = source { drive.driveModel ?? "" } else { "" }
        let plan = RipPlan(
            discPath: source.path,
            discID: disc.discID,
            movieTitle: movieName(for: disc),
            driveModel: driveModel,
            outputFolder: outputFolder,
            verify: VerifyRead(rawValue: defaults.string(forKey: SettingsKey.verifyRead) ?? "") ?? .auto,
            retries: defaults.object(forKey: SettingsKey.retries) as? Int ?? 8,
            keepStaging: defaults.bool(forKey: SettingsKey.keepStaging),
            tracks: trackSelections,
            defaultAudio: defaultAudio,
            movie: identifiedMovie)

        rip = session
        Task {
            await session.start(plan)
            ripFinished(session)
        }
    }

    /// Batch flow: announce the result and, if asked, eject so the next disc can go in.
    private func ripFinished(_ session: RipSession) {
        guard rip === session, session.notice == nil else { return }
        NSSound(named: session.allFinished ? "Glass" : "Basso")?.play()
        NSApp.requestUserAttention(.informationalRequest)
        if session.allFinished, UserDefaults.standard.bool(forKey: SettingsKey.ejectWhenDone) { eject() }
    }

    /// A message if staging or output lacks room for `bytes` (with 1 GB slack), nil if fine.
    private static func spaceProblem(bytes: Int64, staging: URL, output: URL) -> String? {
        // The folders may not exist yet; ask the nearest existing ancestor.
        func values(_ url: URL) -> URLResourceValues? {
            var probe = url
            while !FileManager.default.fileExists(atPath: probe.path), probe.pathComponents.count > 1 {
                probe.deleteLastPathComponent()
            }
            return try? probe.resourceValues(forKeys: [.volumeURLKey, .volumeAvailableCapacityForImportantUsageKey])
        }
        func available(_ url: URL) -> Int64? { values(url)?.volumeAvailableCapacityForImportantUsage }
        func volume(_ url: URL) -> URL? { values(url)?.volume }
        let slack: Int64 = 1 << 30
        let sameVolume = volume(staging) == volume(output)
        let needed = (sameVolume ? 2 * bytes : bytes) + slack
        func describe(_ n: Int64) -> String { n.formatted(.byteCount(style: .file)) }
        if let free = available(staging), free < needed {
            return "Not enough free disk space. This rip needs about \(describe(needed)) (the raw title data plus the MKV), but only \(describe(free)) is available."
        }
        if !sameVolume, let free = available(output), free < bytes + slack {
            return "Not enough free space in the output folder. The MKV needs about \(describe(bytes)), but only \(describe(free)) is available there."
        }
        return nil
    }

    func cancelRip() {
        rip?.cancel()
    }

    /// Cancels a running rip (it can resume later) and hides the rip panel.
    func endRip() {
        rip?.cancel()
        rip = nil
    }

    /// The rip panel's Done button.
    func dismissRip() {
        endRip()
        // The disc went away during the rip; now that the panel is dismissed, reset.
        if source == nil, case .loaded = state {
            state = .idle
            selectedTitles = []
            trackSelections = [:]
            drivesChanged()
        }
    }

    private func load(_ disc: Disc) {
        state = .loaded(disc)
        selectedTitles = disc.mainFeature.map { [$0.number] } ?? []
        let preferences = TrackPreferences.load()
        for title in disc.titles {
            trackSelections[title.number] = preferences.selection(for: title)
        }
        autoRipAfterLookup = isDriveSource && UserDefaults.standard.bool(forKey: SettingsKey.autoRip)
        identify(disc)
    }

    // MARK: - Identification

    var identifiedMovie: MovieMatch? {
        if case let .identified(movie) = identification { movie } else { nil }
    }

    /// "Amadeus (1984)" once identified, otherwise the tidied volume label.
    func movieName(for disc: Disc) -> String {
        identifiedMovie?.displayName
            ?? (disc.volumeLabel.isEmpty ? "Untitled Disc" : disc.volumeLabel.prettifiedVolumeLabel)
    }

    /// Looks the disc up on TMDb (or recalls an earlier answer), then starts a
    /// pending auto-rip so batch rips get the right name.
    func identify(_ disc: Disc) {
        lookupTask?.cancel()
        if let known = IdentificationStore.lookup(disc.discID) {
            identification = .identified(known)
            lookupFinished()
            return
        }
        guard let client = TMDbClient.configured else {
            identification = .notConfigured
            lookupFinished()
            return
        }
        identification = .looking
        let minutes = disc.mainFeature.map { $0.duration.seconds / 60 }
        lookupTask = Task {
            do {
                let (query, decision) = try await TitleLookup.identify(label: disc.volumeLabel, minutes: minutes,
                                                                       client: client)
                guard !Task.isCancelled else { return }
                switch decision {
                case let .confident(movie):
                    identification = .identified(movie)
                    IdentificationStore.remember(movie, for: disc.discID)
                case let .ambiguous(candidates):
                    identification = .choose(candidates, query: query.text)
                case .nothing:
                    identification = .unmatched(query: query.text)
                }
            } catch {
                guard !Task.isCancelled else { return }
                identification = .failed(error.localizedDescription)
            }
            lookupFinished()
        }
    }

    /// The user's pick from the chooser; nil means "use the disc label".
    func choose(_ movie: MovieMatch?) {
        guard let disc else { return }
        IdentificationStore.remember(movie, for: disc.discID)
        identification = movie.map { .identified($0) } ?? .unmatched(query: LabelCleaner.query(for: disc.volumeLabel).text)
        isChoosingMovie = false
    }

    private func lookupFinished() {
        guard autoRipAfterLookup else { return }
        autoRipAfterLookup = false
        startRip()
    }

    // MARK: - Selection bindings

    func isTitleSelected(_ title: Int) -> Bool { selectedTitles.contains(title) }

    func setTitle(_ title: Int, selected: Bool) {
        if selected { selectedTitles.insert(title) } else { selectedTitles.remove(title) }
    }

    func isAudioSelected(title: Int, track: Int) -> Bool {
        trackSelections[title]?.audio.contains(track) ?? false
    }

    func setAudio(title: Int, track: Int, selected: Bool) {
        if selected { trackSelections[title]?.audio.insert(track) } else { trackSelections[title]?.audio.remove(track) }
    }

    func isSubtitleSelected(title: Int, track: Int) -> Bool {
        trackSelections[title]?.subtitles.contains(track) ?? false
    }

    func setSubtitle(title: Int, track: Int, selected: Bool) {
        if selected { trackSelections[title]?.subtitles.insert(track) } else { trackSelections[title]?.subtitles.remove(track) }
    }
}
