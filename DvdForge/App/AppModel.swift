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

    let drives = DriveMonitor()
    private(set) var source: Source?
    private(set) var state: State = .idle
    private(set) var rip: RipSession?

    var selectedTitles: Set<Int> = []
    var isImporting = false
    var trackSelections: [Int: TrackSelection] = [:]

    @ObservationIgnored private var scanTask: Task<Void, Never>?

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
                // Our disc was ejected.
                close()
                return
            }
            source = .drive(now)  // pick up the volume name once mounted
        }
        // A newly inserted disc takes over unless the user is browsing a file.
        if source == nil, let disc = drives.discs.first {
            open(.drive(disc))
        }
    }

    func open(_ source: Source) {
        scanTask?.cancel()
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
                state = .failed(error.localizedDescription, log: log)
            }
        }
    }

    func rescan() {
        if let source { open(source) }
    }

    func close() {
        scanTask?.cancel()
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
        let driveModel = if case let .drive(drive) = source { drive.driveModel ?? "" } else { "" }
        let plan = RipPlan(
            discPath: source.path,
            discID: disc.discID,
            movieTitle: disc.volumeLabel.isEmpty ? "Untitled Disc" : disc.volumeLabel.prettifiedVolumeLabel,
            driveModel: driveModel,
            outputFolder: defaults.string(forKey: SettingsKey.outputFolder).map { URL(filePath: $0) }
                ?? SettingsKey.defaultOutputFolder,
            verify: VerifyRead(rawValue: defaults.string(forKey: SettingsKey.verifyRead) ?? "") ?? .auto,
            retries: defaults.object(forKey: SettingsKey.retries) as? Int ?? 8,
            keepStaging: defaults.bool(forKey: SettingsKey.keepStaging),
            tracks: trackSelections)

        let session = RipSession(titles: titles, discID: disc.discID)
        rip = session
        Task { await session.start(plan) }
    }

    func cancelRip() {
        rip?.cancel()
    }

    /// Cancels a running rip (it can resume later) and hides the rip panel.
    func endRip() {
        rip?.cancel()
        rip = nil
    }

    private func load(_ disc: Disc) {
        state = .loaded(disc)
        selectedTitles = disc.mainFeature.map { [$0.number] } ?? []
        for title in disc.titles {
            trackSelections[title.number] = TrackSelection(
                audio: Set(title.audio.map(\.number)),
                subtitles: Set(title.subtitles.map(\.number)))
        }
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
