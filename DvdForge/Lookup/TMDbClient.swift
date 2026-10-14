import Foundation

/// A movie as TMDb describes it, trimmed to what dvdForge uses.
struct MovieMatch: Codable, Sendable, Hashable, Identifiable {
    var id: Int             // TMDb movie id
    var title: String
    var year: Int?
    var runtimeMinutes: Int?
    var posterPath: String?
    var overview: String?

    /// "Amadeus (1984)": the Plex/Jellyfin/Infuse naming convention.
    var displayName: String { year.map { "\(title) (\($0))" } ?? title }

    var posterURL: URL? {
        posterPath.flatMap { URL(string: "https://image.tmdb.org/t/p/w154\($0)") }
    }

    var pageURL: URL { URL(string: "https://www.themoviedb.org/movie/\(id)")! }
}

/// Minimal client for The Movie Database (https://developer.themoviedb.org).
/// Accepts either credential TMDb hands out: a v3 API key (32 hex characters,
/// sent as a query parameter) or a v4 read access token (a JWT, sent as a
/// bearer token).
struct TMDbClient: Sendable {
    enum Failure: LocalizedError {
        case unauthorized
        case http(Int)
        case unreadable

        var errorDescription: String? {
            switch self {
            case .unauthorized: "TMDb rejected the API key. Check it in Settings → Online Lookup."
            case let .http(code): "TMDb returned an error (HTTP \(code))."
            case .unreadable: "TMDb sent a response dvdForge couldn't read."
            }
        }
    }

    static let keychainAccount = "tmdb-credential"
    static let signupURL = URL(string: "https://www.themoviedb.org/settings/api")!

    let credential: String
    var session: URLSession = .shared

    /// The client for the credential saved in Settings, if any.
    static var configured: TMDbClient? {
        guard let key = Keychain.read(keychainAccount)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !key.isEmpty else { return nil }
        return TMDbClient(credential: key)
    }

    private var isBearerToken: Bool { credential.contains(".") }

    // MARK: Endpoints

    /// True if the credential works.
    func verify() async throws {
        _ = try await get("authentication", [:])
    }

    func searchMovies(_ query: String, year: Int? = nil) async throws -> [MovieMatch] {
        var params = ["query": query, "include_adult": "false"]
        if let year { params["year"] = String(year) }
        let json = try await get("search/movie", params)
        guard let results = json["results"] as? [[String: Any]] else { throw Failure.unreadable }
        return results.compactMap(Self.movie)
    }

    /// Fills in the runtime, which search results don't include.
    func details(_ movie: MovieMatch) async throws -> MovieMatch {
        let json = try await get("movie/\(movie.id)", [:])
        var detailed = Self.movie(json) ?? movie
        detailed.runtimeMinutes = (json["runtime"] as? Int).flatMap { $0 > 0 ? $0 : nil }
        return detailed
    }

    // MARK: Plumbing

    private func get(_ path: String, _ params: [String: String]) async throws -> [String: Any] {
        var components = URLComponents(string: "https://api.themoviedb.org/3/\(path)")!
        var items = params.map { URLQueryItem(name: $0.key, value: $0.value) }
        if !isBearerToken { items.append(URLQueryItem(name: "api_key", value: credential)) }
        components.queryItems = items.isEmpty ? nil : items
        var request = URLRequest(url: components.url!, timeoutInterval: 15)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if isBearerToken { request.setValue("Bearer \(credential)", forHTTPHeaderField: "Authorization") }

        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 401 { throw Failure.unauthorized }
        guard (200 ..< 300).contains(status) else { throw Failure.http(status) }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw Failure.unreadable
        }
        return json
    }

    static func movie(_ json: [String: Any]) -> MovieMatch? {
        guard let id = json["id"] as? Int, let title = json["title"] as? String else { return nil }
        let year = (json["release_date"] as? String).flatMap { Int($0.prefix(4)) }
        return MovieMatch(id: id, title: title, year: year, runtimeMinutes: json["runtime"] as? Int,
                          posterPath: json["poster_path"] as? String, overview: json["overview"] as? String)
    }
}
