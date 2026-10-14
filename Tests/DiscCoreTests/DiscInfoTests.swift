import DiscCore
import Foundation
import Testing

/// Tests against Tests/Fixtures/basic.iso, built by Scripts/make-fixture.sh
/// (the test scheme's pre-action runs it if the ISO is missing).
@Suite struct DiscInfoTests {
    static let fixture = URL(filePath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .appending(path: "Fixtures/basic.iso").path

    let info = dc.readDiscInfo(std.string(DiscInfoTests.fixture))

    private func seconds(_ ticks: UInt64) -> Double { Double(ticks) / Double(dc.kTicksPerSecond) }

    @Test func opensFixture() throws {
        #expect(info.ok, "\(String(info.error)) — run Scripts/make-fixture.sh")
        #expect(String(info.volumeLabel) == "DVDFORGE_FIXTURE")
        #expect(String(info.discId).count == 32)
        #expect(info.titles.count == 2)
    }

    @Test func mainTitleStructure() throws {
        try #require(info.titles.count == 2)
        let t = info.titles[0]
        #expect(t.number == 1 && t.titleSet == 1)
        #expect(t.isMainFeature && !t.duplicatesEarlierTitle)
        #expect(t.aspect == .sixteenByNine && !t.pal && t.width == 720 && t.height == 480)
        #expect(abs(seconds(t.durationTicks) - 24) < 0.5)
        #expect(t.sectorCount > 0 && t.cells.count >= 3)
        #expect(t.palette.count == 16)

        try #require(t.chapters.count == 3)
        for (i, expected) in [0.0, 8.0, 16.0].enumerated() {
            #expect(abs(seconds(t.chapters[i].startTicks) - expected) < 0.5, "chapter \(i + 1)")
        }

        try #require(t.audio.count == 2)
        #expect(t.audio[0].codec == .ac3 && t.audio[0].streamId == 0x80 && String(t.audio[0].language) == "en")
        #expect(t.audio[1].codec == .ac3 && t.audio[1].streamId == 0x81 && String(t.audio[1].language) == "fr")
        #expect(t.audio[0].channels == 2 && t.audio[0].sampleRate == 48000)

        try #require(t.subtitles.count == 1)
        #expect(t.subtitles[0].streamId == 0x20 && String(t.subtitles[0].language) == "en")
    }

    @Test func lpcmTitle() throws {
        try #require(info.titles.count == 2)
        let t = info.titles[1]
        #expect(t.titleSet == 2 && !t.isMainFeature)
        #expect(t.aspect == .fourByThree)
        #expect(abs(seconds(t.durationTicks) - 6) < 0.5)
        #expect(t.chapters.count == 1)
        try #require(t.audio.count == 1)
        #expect(t.audio[0].codec == .lpcm && t.audio[0].streamId == 0xA0)
        #expect(t.audio[0].bitsPerSample == 16 && String(t.audio[0].language) == "fr")
        #expect(t.subtitles.isEmpty)
    }

    @Test func reportsUnopenablePath() {
        let bad = dc.readDiscInfo(std.string("/nonexistent.iso"))
        #expect(!bad.ok && !String(bad.error).isEmpty)
    }
}

@Suite struct ClassifyTitlesTests {
    private func title(_ number: Int32, set: Int32, seconds: UInt64, cells: [(UInt32, UInt32)]) -> dc.Title {
        var t = dc.Title()
        t.number = number
        t.titleSet = set
        t.durationTicks = seconds * dc.kTicksPerSecond
        for (first, last) in cells {
            var c = dc.CellRange()
            c.firstSector = first
            c.lastSector = last
            t.cells.push_back(c)
        }
        return t
    }

    @Test func longestUniqueTitleIsMain() {
        var titles = dc.TitleList()
        titles.push_back(title(1, set: 1, seconds: 60, cells: [(0, 99)]))
        titles.push_back(title(2, set: 1, seconds: 5400, cells: [(100, 999), (1000, 1999)]))
        titles.push_back(title(3, set: 1, seconds: 30, cells: [(2000, 2099)]))
        dc.classifyTitles(&titles)
        #expect(!titles[0].isMainFeature && titles[1].isMainFeature && !titles[2].isMainFeature)
    }

    @Test func duplicatesAreFlaggedAndNeverMain() {
        var titles = dc.TitleList()
        titles.push_back(title(1, set: 1, seconds: 5400, cells: [(100, 999)]))
        titles.push_back(title(2, set: 1, seconds: 5400, cells: [(100, 999)]))  // same cells
        titles.push_back(title(3, set: 2, seconds: 5400, cells: [(100, 999)]))  // other VTS: distinct
        dc.classifyTitles(&titles)
        #expect(!titles[0].duplicatesEarlierTitle && titles[0].isMainFeature)
        #expect(titles[1].duplicatesEarlierTitle && !titles[1].isMainFeature)
        #expect(!titles[2].duplicatesEarlierTitle && !titles[2].isMainFeature)
    }
}
