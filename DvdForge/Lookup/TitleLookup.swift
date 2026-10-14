import Foundation

/// Turns a DVD volume label into a search query.
///
/// Labels are short, upper-case and full of authoring noise:
/// "DAREDEVIL_15_WS" (UK rating + widescreen), "ELEKTRA_169",
/// "HOBBIT_DESOLATION_OF_SMAUG_D1" (disc 1), "HOUSE_OF_CARDS_SEASON2_DISC1".
enum LabelCleaner {
    struct Query: Equatable, Sendable {
        var text: String
        var year: Int?
    }

    private static let noise: Set<String> = [
        "WS", "FS", "WIDESCREEN", "FULLSCREEN", "169", "16X9", "43", "4X3", "LB", "LETTERBOX",
        "DVD", "DVD9", "DVD5", "NTSC", "PAL", "R1", "R2", "R4", "SE", "CE", "UE", "AE",
        "SPECIAL", "COLLECTORS", "EDITION", "DELUXE", "ULTIMATE", "MOVIE",
    ]
    private static let ratings: Set<String> = ["U", "PG", "12", "12A", "15", "18"]

    static func query(for label: String) -> Query {
        let tokens = label.uppercased()
            .replacingOccurrences(of: "[_\\-.]", with: " ", options: .regularExpression)
            .split(separator: " ").map(String.init)
        var kept: [String] = []
        var year: Int?
        for (i, token) in tokens.enumerated() {
            let next = i + 1 < tokens.count ? tokens[i + 1] : nil
            if noise.contains(token) { continue }
            // A UK rating sits just before a format token ("DAREDEVIL_15_WS"); at the
            // end it is more likely part of the title ("OCEANS_12").
            if ratings.contains(token), i > 0, let next, noise.contains(next) { continue }
            if token.range(of: "^(D|DISC|DISK|CD|SIDE)[0-9]+$", options: .regularExpression) != nil { continue }
            if token.range(of: "^(S|SEASON)[0-9]+$", options: .regularExpression) != nil { continue }
            if ["DISC", "DISK", "SEASON"].contains(token), next.flatMap(Int.init) != nil { continue }
            if let n = Int(token), (1900 ... 2099).contains(n), i > 0 {
                year = n
                continue
            }
            if i > 0, Int(token) != nil, ["DISC", "DISK", "SEASON"].contains(tokens[i - 1]) { continue }
            kept.append(token)
        }
        let text = kept.map { $0.prefix(1) + $0.dropFirst().lowercased() }.joined(separator: " ")
        return Query(text: text.isEmpty ? label : text, year: year)
    }

    /// Lower-cased letters and digits, without leading articles; for comparing
    /// "The Hobbit: The Desolation of Smaug" with "Hobbit Desolation Of Smaug".
    static func normalized(_ title: String) -> String {
        let words = title.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty && !["the", "a", "an", "and"].contains($0) }
        return words.joined(separator: " ")
    }
}

/// Picks the movie a disc holds from TMDb search results.
enum MatchPicker {
    enum Decision: Equatable, Sendable {
        case confident(MovieMatch)
        case ambiguous([MovieMatch])
        case nothing
    }

    /// - Parameters:
    ///   - candidates: search results in TMDb's relevance order, ideally with runtimes.
    ///   - minutes: the main title's running time.
    static func decide(query: String, candidates: [MovieMatch], minutes: Double?) -> Decision {
        guard !candidates.isEmpty else { return .nothing }
        let wanted = LabelCleaner.normalized(query)
        let exact = candidates.filter { LabelCleaner.normalized($0.title) == wanted }
        // A single exact title is trusted even if the runtime differs
        // (director's cuts, PAL speed-up, extended editions).
        if exact.count == 1 { return .confident(exact[0]) }

        let pool = exact.count > 1 ? exact : candidates
        guard let minutes else { return .ambiguous(Array(pool.prefix(8))) }
        let ranked = pool.enumerated().sorted { a, b in
            let da = distance(a.element, minutes), db = distance(b.element, minutes)
            return da == db ? a.offset < b.offset : da < db
        }.map(\.element)
        let best = distance(ranked[0], minutes)
        let runnerUp = ranked.count > 1 ? distance(ranked[1], minutes) : .infinity
        if best <= 3, runnerUp - best >= 5 { return .confident(ranked[0]) }
        return .ambiguous(Array(ranked.prefix(8)))
    }

    private static func distance(_ movie: MovieMatch, _ minutes: Double) -> Double {
        movie.runtimeMinutes.map { abs(Double($0) - minutes) } ?? .infinity
    }
}

/// Remembers which movie each disc (by DVD disc ID) turned out to be, so a
/// disc is only ever identified once. Stored in Application Support.
enum IdentificationStore {
    private static var url: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "dvdForge/identifications.json")
    }

    static func lookup(_ discID: String) -> MovieMatch? {
        guard !discID.isEmpty else { return nil }
        return load()[discID]
    }

    static func remember(_ match: MovieMatch?, for discID: String) {
        guard !discID.isEmpty else { return }
        var all = load()
        all[discID] = match
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? JSONEncoder().encode(all).write(to: url, options: .atomic)
    }

    private static func load() -> [String: MovieMatch] {
        guard let data = try? Data(contentsOf: url) else { return [:] }
        return (try? JSONDecoder().decode([String: MovieMatch].self, from: data)) ?? [:]
    }
}

/// Search → fetch runtimes for the most relevant results → decide.
enum TitleLookup {
    static let detailedCandidates = 6

    static func identify(label: String, minutes: Double?, client: TMDbClient) async throws -> (LabelCleaner.Query, MatchPicker.Decision) {
        let query = LabelCleaner.query(for: label)
        var results = try await client.searchMovies(query.text, year: query.year)
        if results.isEmpty, query.year != nil { results = try await client.searchMovies(query.text) }
        let detailed = try await search(results, client: client)
        return (query, MatchPicker.decide(query: query.text, candidates: detailed, minutes: minutes))
    }

    /// Runtimes for the top results, fetched concurrently (search results lack them).
    static func search(_ results: [MovieMatch], client: TMDbClient) async throws -> [MovieMatch] {
        let top = Array(results.prefix(detailedCandidates))
        let detailed = try await withThrowingTaskGroup(of: (Int, MovieMatch).self) { group in
            for (i, movie) in top.enumerated() {
                group.addTask { (i, (try? await client.details(movie)) ?? movie) }
            }
            var out = top
            for try await (i, movie) in group { out[i] = movie }
            return out
        }
        return detailed + results.dropFirst(detailedCandidates)
    }
}
