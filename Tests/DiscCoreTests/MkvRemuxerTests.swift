import DiscCore
import Foundation
import Testing

/// Reads fixture titles, remuxes them to MKV and checks the result with
/// Homebrew's ffprobe/ffmpeg as an independent reference.
@Suite(.serialized) struct MkvRemuxerTests {
    let fixture = DiscInfoTests.fixture

    // MARK: Helpers

    struct Ripped {
        let read: dc.ReadResult
        let mkv: URL
        let remux: dc.RemuxResult
        var staging: String { String(read.stagingPath) }
    }

    func rip(title: Int32, audio: [Int32], subtitles: [Int32], faults: dc.FaultPlan? = nil) throws -> Ripped {
        let dir = ResilientReaderTests.tempDir()
        let (read, _) = ResilientReaderTests.read(fixture, title: title, verify: .automatic, faults: faults, dir: dir)
        try #require(read.completed, "read failed: \(String(read.error))")

        var request = dc.RemuxRequest()
        request.stagingPath = read.stagingPath
        let mkv = dir.appending(path: "out/Title \(title).mkv")
        request.outputPath = std.string(mkv.path)
        request.title = read.title
        for a in audio { request.audioTracks.push_back(a) }
        for s in subtitles { request.subtitleTracks.push_back(s) }
        request.movieTitle = "Fixture"
        request.discId = "0123456789abcdef0123456789abcdef"
        request.badSectors = read.bad

        let job = dc.createRemuxJob(request)
        defer { dc.destroyRemuxJob(job) }
        let remux = dc.runRemuxJob(job)
        try #require(remux.completed, "remux failed: \(String(remux.error))")
        return Ripped(read: read, mkv: mkv, remux: remux)
    }

    static func tool(_ name: String, _ args: [String]) throws -> (out: Data, err: String) {
        let p = Process()
        p.executableURL = URL(filePath: "/opt/homebrew/bin/\(name)")
        p.arguments = args
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        try p.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        let errText = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        p.waitUntilExit()
        return (data, errText)
    }

    func probe(_ url: URL) throws -> [String: Any] {
        let (out, _) = try Self.tool("ffprobe", ["-v", "error", "-of", "json", "-show_streams", "-show_chapters",
                                                 "-show_format", url.path])
        return try #require(JSONSerialization.jsonObject(with: out) as? [String: Any])
    }

    /// MD5 of a stream's packets (copy) or decoded samples (decode), via ffmpeg.
    func md5(_ path: String, format: String? = nil, map: String, copy: Bool) throws -> String {
        var args = ["-v", "error"]
        if let format { args += ["-f", format] }
        args += ["-i", path, "-map", map]
        if copy { args += ["-c", "copy"] } else { args += ["-c:a", "pcm_s16le"] }
        args += ["-f", "md5", "-"]
        let (out, err) = try Self.tool("ffmpeg", args)
        #expect(err.isEmpty, "ffmpeg: \(err)")
        return String(decoding: out, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: Tests

    @Test func mainTitleHasAllTracksChaptersAndTags() throws {
        let r = try rip(title: 1, audio: [0, 1], subtitles: [0])
        let info = try probe(r.mkv)
        let streams = try #require(info["streams"] as? [[String: Any]])
        try #require(streams.count == 4)

        let video = streams[0]
        #expect(video["codec_name"] as? String == "mpeg2video")
        #expect(video["width"] as? Int == 720 && video["height"] as? Int == 480)
        #expect(video["display_aspect_ratio"] as? String == "16:9")

        let langs = streams.map { ($0["tags"] as? [String: Any])?["language"] as? String }
        #expect(streams[1]["codec_name"] as? String == "ac3" && langs[1] == "eng")
        #expect(streams[2]["codec_name"] as? String == "ac3" && langs[2] == "fre")
        #expect((streams[1]["disposition"] as? [String: Int])?["default"] == 1)
        #expect((streams[2]["disposition"] as? [String: Int])?["default"] == 0)
        #expect(streams[3]["codec_name"] as? String == "dvd_subtitle" && langs[3] == "eng")

        let chapters = try #require(info["chapters"] as? [[String: Any]])
        let starts = chapters.compactMap { Double($0["start_time"] as? String ?? "") }
        try #require(starts.count == 3)
        for (got, want) in zip(starts, [0.0, 8.0, 16.0]) { #expect(abs(got - want) < 0.5) }

        let format = try #require(info["format"] as? [String: Any])
        let duration = Double(format["duration"] as? String ?? "") ?? 0
        #expect(abs(duration - 24) < 0.5, "duration \(duration)")
        let tags = format["tags"] as? [String: Any] ?? [:]
        #expect(tags["DVDFORGE_DISC_ID"] as? String == "0123456789abcdef0123456789abcdef")
        #expect(tags["title"] as? String == "Fixture")
        #expect(r.remux.timestampDiscontinuities == 0)
    }

    @Test func outputDecodesWithoutErrors() throws {
        let r = try rip(title: 1, audio: [0, 1], subtitles: [0])
        let (_, err) = try Self.tool("ffmpeg", ["-v", "error", "-i", r.mkv.path, "-map", "0", "-c:s", "dvdsub", "-f", "null", "-"])
        #expect(err.isEmpty, "decode errors: \(err)")
    }

    @Test func videoAndAc3AreBitIdenticalToTheDisc() throws {
        let r = try rip(title: 1, audio: [0, 1], subtitles: [])
        #expect(try md5(r.staging, format: "mpeg", map: "0:v", copy: true) == md5(r.mkv.path, map: "0:v", copy: true))
        #expect(try md5(r.staging, format: "mpeg", map: "0:a:0", copy: true) == md5(r.mkv.path, map: "0:a:0", copy: true))
    }

    @Test func trackSelectionIsHonoured() throws {
        let r = try rip(title: 1, audio: [1], subtitles: [])
        let streams = try #require(try probe(r.mkv)["streams"] as? [[String: Any]])
        #expect(streams.count == 2)
        #expect((streams[1]["tags"] as? [String: Any])?["language"] as? String == "fre")
    }

    @Test func lpcmBecomesLosslessFlac() throws {
        let r = try rip(title: 2, audio: [0], subtitles: [])
        let streams = try #require(try probe(r.mkv)["streams"] as? [[String: Any]])
        try #require(streams.count == 2)
        #expect(streams[1]["codec_name"] as? String == "flac")
        #expect(streams[0]["display_aspect_ratio"] as? String == "4:3")
        // Decoded samples are identical: FLAC is lossless.
        #expect(try md5(r.staging, format: "mpeg", map: "0:a", copy: false) == md5(r.mkv.path, map: "0:a", copy: false))
    }

    @Test func clockRestartBetweenCellsIsRebased() throws {
        let r = try rip(title: 3, audio: [0], subtitles: [])
        #expect(r.remux.timestampDiscontinuities >= 1)
        let format = try #require(try probe(r.mkv)["format"] as? [String: Any])
        let duration = Double(format["duration"] as? String ?? "") ?? 0
        #expect(abs(duration - 12) < 0.5, "duration \(duration)")
        let (_, err) = try Self.tool("ffmpeg", ["-v", "error", "-i", r.mkv.path, "-map", "0", "-c:s", "dvdsub", "-f", "null", "-"])
        #expect(err.isEmpty, "decode errors: \(err)")
    }

    @Test func damagedTitleStillRemuxes() throws {
        let info = dc.readDiscInfo(std.string(fixture))
        let base = info.titles[0].cells[0].firstSector
        var faults = dc.FaultPlan()
        for s in base + 1000 ..< base + 1040 { faults.hardBad.push_back(s) }
        let r = try rip(title: 1, audio: [0], subtitles: [], faults: faults)
        #expect(r.read.bad == 40)
        let format = try #require(try probe(r.mkv)["format"] as? [String: Any])
        #expect(abs((Double(format["duration"] as? String ?? "") ?? 0) - 24) < 0.5)
    }

    @Test func languageCodes() {
        #expect(String(dc.matroskaLanguage(std.string("en"))) == "eng")
        #expect(String(dc.matroskaLanguage(std.string("DE"))) == "ger")
        #expect(String(dc.matroskaLanguage(std.string("xx"))) == "und")
    }
}
