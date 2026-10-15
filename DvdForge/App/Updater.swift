import Foundation
import Observation
import Sparkle

/// Sparkle updates from the appcast attached to the latest GitHub release
/// (SUFeedURL in Info.plist). Sparkle asks the user before checking
/// automatically, so nothing goes out until they agree.
@MainActor @Observable
final class Updater {
    static let shared = Updater()

    private let controller: SPUStandardUpdaterController?
    private var observations: [NSKeyValueObservation] = []
    private(set) var canCheckForUpdates = false

    var checksAutomatically = false {
        didSet {
            if controller?.updater.automaticallyChecksForUpdates != checksAutomatically {
                controller?.updater.automaticallyChecksForUpdates = checksAutomatically
            }
        }
    }

    private init() {
        // Not while hosting unit tests, where an update prompt would stall the run.
        guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil else {
            controller = nil
            return
        }
        controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
        guard let updater = controller?.updater else { return }
        observations = [
            updater.observe(\.canCheckForUpdates, options: [.initial, .new]) { updater, _ in
                let can = updater.canCheckForUpdates
                Task { @MainActor in Updater.shared.canCheckForUpdates = can }
            },
            // Sparkle changes this itself when the user answers its first-run prompt.
            updater.observe(\.automaticallyChecksForUpdates, options: [.initial, .new]) { updater, _ in
                let on = updater.automaticallyChecksForUpdates
                Task { @MainActor in Updater.shared.checksAutomatically = on }
            },
        ]
    }

    var isAvailable: Bool { controller != nil }

    func checkForUpdates() {
        controller?.checkForUpdates(nil)
    }
}
