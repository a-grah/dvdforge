@testable import dvdForge
import Foundation
import Testing

private func title(audio: [(String, TrackPurpose)], subtitles: [String]) -> DiscTitle {
    DiscTitle(
        number: 1, titleSet: 1, angles: 1, duration: .seconds(5400), byteCount: 0, width: 720, height: 480,
        isPAL: false, aspect: .sixteenByNine, chapters: [],
        audio: audio.enumerated().map { i, a in
            AudioTrackInfo(number: i, streamID: 0x80 + i, codec: .ac3, channels: 6, sampleRate: 48000,
                           bitsPerSample: 0, language: a.0, purpose: a.1)
        },
        subtitles: subtitles.enumerated().map { i, l in
            SubtitleTrackInfo(number: i, streamID: 0x20 + i, language: l, purpose: .normal)
        },
        isMainFeature: true, isDuplicate: false)
}

@Suite struct TrackPreferencesTests {
    let disc = title(audio: [("fr", .normal), ("en", .commentary), ("en", .normal), ("de", .normal)],
                     subtitles: ["en", "fr", "es"])

    @Test func parsesLanguageList() {
        #expect(TrackPreferences.parse("EN, fr;de  xyz") == ["en", "fr", "de"])
    }

    @Test func allKeepsEverything() {
        let p = TrackPreferences(languages: ["en"], audio: .all, subtitles: .all)
        #expect(p.selection(for: disc) == .init(audio: [0, 1, 2, 3], subtitles: [0, 1, 2]))
    }

    @Test func preferredFiltersByLanguage() {
        let p = TrackPreferences(languages: ["en", "fr"], audio: .preferred, subtitles: .preferred)
        #expect(p.selection(for: disc) == .init(audio: [0, 1, 2], subtitles: [0, 1]))
    }

    @Test func preferredNeverLeavesATitleSilent() {
        let p = TrackPreferences(languages: ["ja"], audio: .preferred, subtitles: .preferred)
        let s = p.selection(for: disc)
        #expect(s.audio == [0, 1, 2, 3])
        #expect(s.subtitles.isEmpty)
    }

    @Test func subtitlesCanBeTurnedOff() {
        let p = TrackPreferences(languages: ["en"], audio: .all, subtitles: .none)
        #expect(p.selection(for: disc).subtitles.isEmpty)
    }

    @Test func defaultAudioSkipsCommentaryAndFollowsPriority() {
        let p = TrackPreferences(languages: ["en", "fr"], audio: .all, subtitles: .all)
        #expect(p.defaultAudio(for: disc, selected: [0, 1, 2, 3]) == 2)
        #expect(p.defaultAudio(for: disc, selected: [0, 1]) == 0)  // English kept is only commentary
        #expect(TrackPreferences(languages: ["ja"], audio: .all, subtitles: .all)
            .defaultAudio(for: disc, selected: [0, 1, 2, 3]) == nil)
    }
}

@Suite struct RipReportTests {
    @Test func reportSitsNextToTheMKV() {
        let mkv = URL(filePath: "/Movies/Amadeus/Amadeus.mkv")
        #expect(RipReport.url(forMKV: mkv).path == "/Movies/Amadeus/Amadeus.dvdforge.json")
    }

    @Test func roundTripsAndIsFoundByScanning() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "dvdforge-reports-\(UUID().uuidString)")
        let movie = folder.appending(path: "Amadeus")
        try FileManager.default.createDirectory(at: movie, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        let report = RipReport(
            date: Date(timeIntervalSince1970: 1_790_000_000), software: "test",
            disc: .init(label: "Amadeus", id: "858c0d27", source: "/dev/rdisk4", drive: "TSSTcorp"),
            title: .init(number: 2, durationSeconds: 10822.1, chapters: 46, sectors: 3_774_956, isMainFeature: true),
            read: .init(verifyMode: "auto", verifyRan: true, retriesPerSector: 8, resumed: false, readErrors: 3,
                        unreadableSectors: 2, unstableSectors: 0, repairedSectors: 1,
                        damage: [.init(chapter: 12, startSeconds: 2710.5, sectors: 2, unstable: false)]),
            output: .init(file: "Amadeus.mkv", bytes: 7_579_886_022, audioTracks: ["English 5.1"],
                          subtitleTracks: [], timestampDiscontinuities: 0, warnings: []))
        try report.write(to: RipReport.url(forMKV: movie.appending(path: "Amadeus.mkv")))

        let found = await RipReport.loadAll(in: folder)
        try #require(found.count == 1)
        var loaded = found[0]
        #expect(loaded.mkvURL?.lastPathComponent == "Amadeus.mkv")
        #expect(!loaded.isClean)
        loaded.reportURL = nil
        #expect(loaded == report)
    }
}

@Suite struct NamingTests {
    @Test func volumeLabelsAreTidied() {
        #expect("STAR_WARS_EP4".prettifiedVolumeLabel == "Star Wars Ep4")
        #expect("AMADEUS".prettifiedVolumeLabel == "Amadeus")
    }

    @Test func fileNamesAreSafe() {
        #expect("AC/DC: Live".sanitizedFileName == "AC-DC- Live")
        #expect("  ...  ".sanitizedFileName == "Untitled Disc")
    }
}
