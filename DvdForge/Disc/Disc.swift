import DiscCore
import Foundation

// Swift-side value model of a disc. DiscCore's C++ structs are copied into
// these Sendable types right after reading, so the rest of the app (and
// SwiftUI) never touches C++ types or crosses actors with them.

struct Disc: Sendable, Hashable {
    var volumeLabel: String
    var discID: String
    var titles: [DiscTitle]
    var warnings: [String]

    var mainFeature: DiscTitle? { titles.first(where: \.isMainFeature) }
}

struct DiscTitle: Sendable, Hashable, Identifiable {
    var number: Int
    var titleSet: Int
    var angles: Int
    var duration: Duration
    var byteCount: Int64
    var width: Int
    var height: Int
    var isPAL: Bool
    var aspect: Aspect
    var chapters: [DiscChapter]
    var audio: [AudioTrackInfo]
    var subtitles: [SubtitleTrackInfo]
    var isMainFeature: Bool
    var isDuplicate: Bool

    var id: Int { number }

    enum Aspect: String, Sendable { case fourByThree = "4:3", sixteenByNine = "16:9", unknown = "?" }
}

struct DiscChapter: Sendable, Hashable, Identifiable {
    var number: Int
    var start: Duration
    var duration: Duration
    var id: Int { number }
}

enum TrackPurpose: String, Sendable {
    case normal = "", visuallyImpaired = "Visually impaired", commentary = "Commentary", other = "Other"
}

struct AudioTrackInfo: Sendable, Hashable, Identifiable {
    enum Codec: String, Sendable { case ac3 = "AC3", dts = "DTS", lpcm = "LPCM", mpeg = "MPEG", unknown = "Unknown" }

    var number: Int
    var streamID: Int
    var codec: Codec
    var channels: Int
    var sampleRate: Int
    var bitsPerSample: Int
    var language: String
    var purpose: TrackPurpose
    var id: Int { number }

    var channelLayout: String {
        switch channels {
        case 1: "1.0"
        case 2: "2.0"
        case 6: "5.1"
        case 8: "7.1"
        default: "\(channels)ch"
        }
    }
}

struct SubtitleTrackInfo: Sendable, Hashable, Identifiable {
    var number: Int
    var streamID: Int
    var language: String
    var purpose: TrackPurpose
    var id: Int { number }
}

// MARK: - Reading

enum DiscReadError: LocalizedError {
    case unreadable(String, log: [String])

    var errorDescription: String? {
        switch self {
        case let .unreadable(message, _): message
        }
    }
}

enum DiscReader {
    /// Reads the structure of the DVD at `path` (/dev/rdiskN, ISO, or VIDEO_TS
    /// folder) off the main thread; CSS key retrieval can take a while.
    static func read(path: String) async throws -> Disc {
        try await Task.detached(priority: .userInitiated) {
            let info = dc.readDiscInfo(std.string(path))
            guard info.ok else {
                throw DiscReadError.unreadable(String(info.error), log: info.log.map { String($0) })
            }
            return Disc(info)
        }.value
    }
}

// MARK: - Bridging from DiscCore

extension Disc {
    init(_ info: dc.DiscInfo) {
        volumeLabel = String(info.volumeLabel)
        discID = String(info.discId)
        titles = info.titles.map(DiscTitle.init)
        warnings = info.log.map { String($0) }
    }
}

private func discDuration(_ ticks: UInt64) -> Duration {
    // 90 kHz ticks → exact nanoseconds (1 tick = 100_000 / 9 ns).
    .nanoseconds(Int64(ticks) * 100_000 / 9)
}

private extension AudioTrackInfo.Codec {
    init(_ c: dc.AudioCodec) {
        self = switch c {
        case .ac3: .ac3
        case .dts: .dts
        case .lpcm: .lpcm
        case .mpeg: .mpeg
        default: .unknown
        }
    }
}

private extension TrackPurpose {
    init(_ p: dc.TrackPurpose) {
        self = switch p {
        case .normal: .normal
        case .visuallyImpaired: .visuallyImpaired
        case .commentary: .commentary
        default: .other
        }
    }
}

extension DiscTitle {
    init(_ t: dc.Title) {
        number = Int(t.number)
        titleSet = Int(t.titleSet)
        angles = Int(t.angles)
        duration = discDuration(t.durationTicks)
        byteCount = Int64(t.sectorCount) * 2048
        width = Int(t.width)
        height = Int(t.height)
        isPAL = t.pal
        aspect = switch t.aspect {
        case .fourByThree: .fourByThree
        case .sixteenByNine: .sixteenByNine
        default: .unknown
        }
        chapters = t.chapters.map {
            DiscChapter(number: Int($0.number), start: discDuration($0.startTicks),
                        duration: discDuration($0.durationTicks))
        }
        audio = t.audio.map { a in
            AudioTrackInfo(
                number: Int(a.number), streamID: Int(a.streamId),
                codec: AudioTrackInfo.Codec(a.codec),
                channels: Int(a.channels), sampleRate: Int(a.sampleRate), bitsPerSample: Int(a.bitsPerSample),
                language: String(a.language), purpose: TrackPurpose(a.purpose))
        }
        subtitles = t.subtitles.map {
            SubtitleTrackInfo(number: Int($0.number), streamID: Int($0.streamId),
                              language: String($0.language), purpose: TrackPurpose($0.purpose))
        }
        isMainFeature = t.isMainFeature
        isDuplicate = t.duplicatesEarlierTitle
    }
}
