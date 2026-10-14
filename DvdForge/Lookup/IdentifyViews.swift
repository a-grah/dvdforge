import AppKit
import SwiftUI

/// One line under the disc name: what the disc was identified as, with a way
/// to change it.
struct IdentityRow: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        HStack(spacing: 6) {
            switch model.identification {
            case .notConfigured:
                Text("Name files by movie title:")
                    .foregroundStyle(.secondary)
                Button("Add a TMDb key…") { openSettings() }
                    .buttonStyle(.link)
            case .looking:
                ProgressView().controlSize(.small)
                Text("Looking up on TMDb…").foregroundStyle(.secondary)
            case let .identified(movie):
                Image(systemName: "film").foregroundStyle(.secondary)
                Link(movie.displayName, destination: movie.pageURL)
                if let runtime = movie.runtimeMinutes {
                    Text("· \(runtime) min").foregroundStyle(.secondary)
                }
                Button("Change…") { model.isChoosingMovie = true }
                    .buttonStyle(.link)
            case .choose:
                Image(systemName: "questionmark.circle").foregroundStyle(.orange)
                Text("Several possible matches.")
                Button("Choose…") { model.isChoosingMovie = true }
                    .buttonStyle(.link)
            case .unmatched:
                Text("Not identified; files use the disc label.").foregroundStyle(.secondary)
                Button("Search…") { model.isChoosingMovie = true }
                    .buttonStyle(.link)
            case let .failed(message):
                Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)
                Text(message).foregroundStyle(.secondary).lineLimit(1)
                Button("Retry") { if let disc = model.disc { model.identify(disc) } }
                    .buttonStyle(.link)
            }
        }
        .font(.callout)
        .disabled(model.rip != nil)
    }
}

/// Search TMDb by hand and pick the right movie.
struct MovieChooser: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let disc: Disc

    @State private var query = ""
    @State private var results: [MovieMatch] = []
    @State private var selection: MovieMatch.ID?
    @State private var searching = false
    @State private var error: String?

    private var discMinutes: Int? { disc.mainFeature.map { Int(($0.duration.seconds / 60).rounded()) } }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Which movie is this?").font(.title3.bold())
            Text("Disc label \(disc.volumeLabel)\(discMinutes.map { ", main title \($0) min" } ?? "")")
                .foregroundStyle(.secondary)
            HStack {
                TextField("Search TMDb", text: $query)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { Task { await search() } }
                Button("Search") { Task { await search() } }
                    .disabled(query.isEmpty || searching)
            }
            Group {
                if searching {
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let error {
                    Text(error).foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if results.isEmpty {
                    Text("No results.").foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List(results, selection: $selection) { movie in
                        MovieRow(movie: movie, discMinutes: discMinutes).tag(movie.id)
                    }
                }
            }
            .frame(minHeight: 280)
            HStack {
                Button("Use Disc Label") { model.choose(nil) }
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Choose") { model.choose(results.first { $0.id == selection }) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(selection == nil)
            }
            Text("This product uses the TMDB API but is not endorsed or certified by TMDB.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(20)
        .frame(width: 560, height: 520)
        .task { await start() }
    }

    private func start() async {
        switch model.identification {
        case let .choose(candidates, query: q):
            query = q
            results = candidates
            selection = candidates.first?.id
        case let .unmatched(query: q):
            query = q
            await search()
        default:
            query = LabelCleaner.query(for: disc.volumeLabel).text
            await search()
        }
    }

    private func search() async {
        guard let client = TMDbClient.configured else {
            error = "Add a TMDb API key in Settings → Online Lookup to search."
            return
        }
        searching = true
        error = nil
        defer { searching = false }
        do {
            results = try await TitleLookup.search(try await client.searchMovies(query), client: client)
            selection = results.first?.id
        } catch {
            self.error = error.localizedDescription
        }
    }
}

private struct MovieRow: View {
    let movie: MovieMatch
    let discMinutes: Int?

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            AsyncImage(url: movie.posterURL) { image in
                image.resizable().aspectRatio(contentMode: .fill)
            } placeholder: {
                Rectangle().fill(.quaternary)
            }
            .frame(width: 40, height: 60)
            .clipShape(RoundedRectangle(cornerRadius: 4))
            VStack(alignment: .leading, spacing: 2) {
                Text(movie.displayName).font(.headline)
                if let runtime = movie.runtimeMinutes {
                    let close = discMinutes.map { abs($0 - runtime) <= 3 } ?? false
                    Label("\(runtime) min", systemImage: close ? "checkmark.circle.fill" : "clock")
                        .font(.caption)
                        .foregroundStyle(close ? .green : .secondary)
                }
                if let overview = movie.overview, !overview.isEmpty {
                    Text(overview).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
            }
        }
        .padding(.vertical, 2)
    }
}

/// Settings → Online Lookup. Each user brings their own TMDb credential; it
/// is kept in their keychain, never in the app or its source.
struct OnlineLookupSettings: View {
    @State private var credential = Keychain.read(TMDbClient.keychainAccount) ?? ""
    @State private var status: Status = .idle

    enum Status: Equatable {
        case idle, testing, ok, failed(String)
    }

    var body: some View {
        Section {
            SecureField("TMDb API key", text: $credential, prompt: Text("API key or read access token"))
                .onSubmit(save)
            HStack {
                Button("Save & Test") {
                    save()
                    Task { await test() }
                }
                .disabled(status == .testing)
                switch status {
                case .idle: EmptyView()
                case .testing: ProgressView().controlSize(.small)
                case .ok: Label("Working", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                case let .failed(message): Label(message, systemImage: "xmark.octagon.fill").foregroundStyle(.red)
                }
                Spacer()
                Link("Get a free key", destination: TMDbClient.signupURL)
            }
            Text("dvdForge looks discs up on The Movie Database to name files \"Title (Year)\", the way Plex, Jellyfin and Infuse expect. Create a free TMDb account, then copy the API key (or API read access token) from its API settings. The key is stored in your keychain. Without one, files are named from the disc label.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text("This product uses the TMDB API but is not endorsed or certified by TMDB.")
                .font(.caption)
                .foregroundStyle(.tertiary)
        } header: {
            Text("Online Lookup")
        }
    }

    private func save() {
        Keychain.write(TMDbClient.keychainAccount, credential.trimmingCharacters(in: .whitespacesAndNewlines))
        status = .idle
    }

    private func test() async {
        guard let client = TMDbClient.configured else {
            status = .failed("No key entered.")
            return
        }
        status = .testing
        do {
            try await client.verify()
            status = .ok
        } catch {
            status = .failed(error.localizedDescription)
        }
    }
}
