@testable import dvdForge
import Foundation
import Testing

@Suite struct LabelCleanerTests {
    @Test(arguments: [
        ("AMADEUS", "Amadeus", nil),
        ("DAREDEVIL_15_WS", "Daredevil", nil),
        ("ELEKTRA_169", "Elektra", nil),
        ("FANTASTIC_FOUR_169", "Fantastic Four", nil),
        ("HOBBIT_DESOLATION_OF_SMAUG_D1", "Hobbit Desolation Of Smaug", nil),
        ("HOUSE_OF_CARDS_SEASON2_DISC1", "House Of Cards", nil),
        ("INTOLERABLE_CRUELTY", "Intolerable Cruelty", nil),
        ("BLADE_RUNNER_1982_WS", "Blade Runner", 1982),
        ("OCEANS_12", "Oceans 12", nil),
        ("2001_A_SPACE_ODYSSEY", "2001 A Space Odyssey", nil),
    ] as [(String, String, Int?)])
    func cleansLabels(label: String, text: String, year: Int?) {
        #expect(LabelCleaner.query(for: label) == .init(text: text, year: year))
    }

    @Test func normalizesForComparison() {
        #expect(LabelCleaner.normalized("The Hobbit: The Desolation of Smaug")
            == LabelCleaner.normalized("Hobbit Desolation Of Smaug"))
    }
}

@Suite struct MatchPickerTests {
    func movie(_ id: Int, _ title: String, _ year: Int, _ runtime: Int?) -> MovieMatch {
        MovieMatch(id: id, title: title, year: year, runtimeMinutes: runtime)
    }

    @Test func singleExactTitleWinsEvenWithDifferentRuntime() {
        // Director's cut: 180 min disc, TMDb lists the 160 min theatrical runtime.
        let d = MatchPicker.decide(query: "Amadeus", candidates: [
            movie(279, "Amadeus", 1984, 160), movie(9, "Amadeus: The Making Of", 2002, 60),
        ], minutes: 180)
        #expect(d == .confident(movie(279, "Amadeus", 1984, 160)))
    }

    @Test func runtimeSeparatesSameTitledMovies() {
        let d = MatchPicker.decide(query: "Daredevil", candidates: [
            movie(1, "Daredevil", 2003, 103), movie(2, "Daredevil", 1999, 12),
        ], minutes: 103.4)
        #expect(d == .confident(movie(1, "Daredevil", 2003, 103)))
    }

    @Test func articlesAndPunctuationDoNotMatter() {
        let d = MatchPicker.decide(query: "Hobbit Desolation Of Smaug", candidates: [
            movie(57158, "The Hobbit: The Desolation of Smaug", 2013, 161), movie(5, "The Hobbit", 1977, 77),
        ], minutes: 161.3)
        #expect(d == .confident(movie(57158, "The Hobbit: The Desolation of Smaug", 2013, 161)))
    }

    @Test func closeRuntimesAreLeftToTheUser() {
        let a = movie(1, "Fantastic Four", 2005, 106), b = movie(2, "Fantastic Four", 2015, 100)
        guard case let .ambiguous(list) = MatchPicker.decide(query: "Fantastic Four", candidates: [a, b], minutes: 104)
        else { Issue.record("expected ambiguous"); return }
        #expect(list.first == a)  // closest runtime first
    }

    @Test func nothingFound() {
        #expect(MatchPicker.decide(query: "Xyzzy", candidates: [], minutes: 90) == .nothing)
    }
}

@Suite struct TMDbParsingTests {
    @Test func parsesMovieJSON() throws {
        let json = try JSONSerialization.jsonObject(with: Data("""
        {"id": 279, "title": "Amadeus", "release_date": "1984-09-19", "runtime": 160,
         "poster_path": "/1n5VUlCqgmVax1adxGZm8oCFaKc.jpg", "overview": "Mozart..."}
        """.utf8)) as! [String: Any]
        let m = try #require(TMDbClient.movie(json))
        #expect(m.displayName == "Amadeus (1984)" && m.runtimeMinutes == 160)
        #expect(m.posterURL?.absoluteString == "https://image.tmdb.org/t/p/w154/1n5VUlCqgmVax1adxGZm8oCFaKc.jpg")
    }

    @Test func missingReleaseDateHasNoYear() {
        #expect(TMDbClient.movie(["id": 1, "title": "Untitled", "release_date": ""])?.displayName == "Untitled")
    }
}
