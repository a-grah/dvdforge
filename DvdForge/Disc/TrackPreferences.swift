import Foundation

/// Which tracks of a kind to keep by default.
enum TrackChoice: String, CaseIterable, Identifiable, Sendable {
    case all, preferred, none
    var id: Self { self }
}

/// The user's language preferences, applied when a disc is loaded to pre-select
/// tracks (the user can still change them per title) and to pick the default
/// audio track of the MKV.
struct TrackPreferences: Sendable, Equatable {
    /// ISO 639-1 codes in priority order, e.g. ["en", "fr"].
    var languages: [String]
    var audio: TrackChoice
    var subtitles: TrackChoice

    static var systemLanguage: String { Locale.current.language.languageCode?.identifier ?? "en" }

    static func load(from defaults: UserDefaults = .standard) -> TrackPreferences {
        TrackPreferences(
            languages: parse(defaults.string(forKey: SettingsKey.preferredLanguages) ?? systemLanguage),
            audio: TrackChoice(rawValue: defaults.string(forKey: SettingsKey.audioTracks) ?? "") ?? .all,
            subtitles: TrackChoice(rawValue: defaults.string(forKey: SettingsKey.subtitleTracks) ?? "") ?? .all)
    }

    /// "en, fr; de" → ["en", "fr", "de"]
    static func parse(_ text: String) -> [String] {
        text.lowercased()
            .split(whereSeparator: { $0 == "," || $0 == ";" || $0 == " " })
            .map(String.init)
            .filter { $0.count == 2 }
    }

    func selection(for title: DiscTitle) -> AppModel.TrackSelection {
        AppModel.TrackSelection(
            audio: Set(pick(title.audio.map { ($0.number, $0.language) }, choice: audio, keepSomething: true)),
            subtitles: Set(pick(title.subtitles.map { ($0.number, $0.language) }, choice: subtitles,
                                keepSomething: false)))
    }

    /// The audio track to flag as default: the first non-commentary track in
    /// the highest-priority language among `selected`; nil to keep disc order.
    func defaultAudio(for title: DiscTitle, selected: Set<Int>) -> Int? {
        for language in languages {
            if let track = title.audio.first(where: {
                selected.contains($0.number) && $0.language == language && $0.purpose != .commentary
            }) {
                return track.number
            }
        }
        return nil
    }

    private func pick(_ tracks: [(number: Int, language: String)], choice: TrackChoice, keepSomething: Bool) -> [Int] {
        switch choice {
        case .all:
            return tracks.map(\.number)
        case .none:
            return []
        case .preferred:
            let matching = tracks.filter { languages.contains($0.language) }.map(\.number)
            // Never leave a title silent because none of its tracks is in a preferred language.
            return matching.isEmpty && keepSomething ? tracks.map(\.number) : matching
        }
    }
}
