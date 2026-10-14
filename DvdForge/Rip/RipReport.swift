import DiscCore
import Foundation

/// A record of one ripped title, saved as "<movie>.dvdforge.json" next to the
/// MKV so that, years later, it is clear how the archive was made and whether
/// the disc was damaged when it was read.
struct RipReport: Codable, Sendable, Hashable, Identifiable {
    struct DiscRecord: Codable, Sendable, Hashable {
        var label: String
        var id: String
        var source: String
        var drive: String?
    }

    struct MovieRecord: Codable, Sendable, Hashable {
        var tmdbID: Int
        var title: String
        var year: Int?
    }

    struct TitleRecord: Codable, Sendable, Hashable {
        var number: Int
        var durationSeconds: Double
        var chapters: Int
        var sectors: UInt64
        var isMainFeature: Bool
    }

    struct DamageRecord: Codable, Sendable, Hashable {
        var chapter: Int
        var startSeconds: Double
        var sectors: UInt64
        var unstable: Bool
    }

    struct ReadRecord: Codable, Sendable, Hashable {
        var verifyMode: String
        var verifyRan: Bool
        var retriesPerSector: Int
        var resumed: Bool
        var readErrors: UInt64
        var unreadableSectors: UInt64
        var unstableSectors: UInt64
        var repairedSectors: UInt64
        var damage: [DamageRecord]
    }

    struct OutputRecord: Codable, Sendable, Hashable {
        var file: String
        var bytes: Int64
        var audioTracks: [String]
        var subtitleTracks: [String]
        var timestampDiscontinuities: Int
        var warnings: [String]
    }

    var formatVersion = 1
    var date: Date
    var software: String
    var disc: DiscRecord
    var movie: MovieRecord?
    var title: TitleRecord
    var read: ReadRecord
    var output: OutputRecord

    /// Where this report was loaded from; not part of the file.
    var reportURL: URL?

    enum CodingKeys: String, CodingKey {
        case formatVersion, date, software, disc, movie, title, read, output
    }

    var id: String { reportURL?.path ?? "\(disc.id)-\(title.number)-\(date.timeIntervalSince1970)" }
    var isClean: Bool { read.unreadableSectors == 0 && read.unstableSectors == 0 }
    var mkvURL: URL? { reportURL?.deletingLastPathComponent().appending(path: output.file) }

    static let fileSuffix = ".dvdforge.json"

    static func url(forMKV mkv: URL) -> URL {
        mkv.deletingPathExtension().deletingLastPathComponent()
            .appending(path: mkv.deletingPathExtension().lastPathComponent + fileSuffix)
    }

    static var softwareDescription: String {
        let v = dc.libraryVersions()
        let app = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
        return "dvdForge \(app) (libdvdread \(String(v.libdvdread)), libdvdcss \(String(v.libdvdcss)), libavformat \(String(v.libavformat)))"
    }

    // MARK: Persistence

    func write(to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(self).write(to: url, options: .atomic)
    }

    static func load(from url: URL) throws -> RipReport {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        var report = try decoder.decode(RipReport.self, from: Data(contentsOf: url))
        report.reportURL = url
        return report
    }

    /// Every report under `folder`, newest first. Unreadable files are skipped.
    static func loadAll(in folder: URL) async -> [RipReport] {
        await Task.detached(priority: .userInitiated) { scan(folder) }.value
    }

    private static func scan(_ folder: URL) -> [RipReport] {
        guard let files = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: nil,
                                                         options: [.skipsHiddenFiles, .skipsPackageDescendants])
        else { return [] }
        var reports: [RipReport] = []
        for case let url as URL in files where url.lastPathComponent.hasSuffix(fileSuffix) {
            if let report = try? load(from: url) { reports.append(report) }
        }
        return reports.sorted { $0.date > $1.date }
    }
}

extension RipReport {
    init(plan: RipPlan, title: DiscTitle, read: TitleReadResult, remux: TitleRemuxResult, mkv: URL,
         selection: AppModel.TrackSelection?) {
        let bytes = (try? mkv.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
        self.init(
            date: Date(),
            software: Self.softwareDescription,
            disc: DiscRecord(label: plan.movieTitle, id: plan.discID, source: plan.discPath,
                             drive: plan.driveModel.isEmpty ? nil : plan.driveModel),
            movie: plan.movie.map { MovieRecord(tmdbID: $0.id, title: $0.title, year: $0.year) },
            title: TitleRecord(number: title.number, durationSeconds: title.duration.seconds,
                               chapters: title.chapters.count, sectors: read.totalSectors,
                               isMainFeature: title.isMainFeature),
            read: ReadRecord(
                verifyMode: plan.verify.rawValue, verifyRan: read.verifyRan, retriesPerSector: plan.retries,
                resumed: read.resumed, readErrors: read.readErrors, unreadableSectors: read.bad,
                unstableSectors: read.unstable, repairedSectors: read.repaired,
                damage: read.damage.map {
                    DamageRecord(chapter: $0.chapter, startSeconds: $0.start.seconds, sectors: $0.sectorCount,
                                 unstable: $0.isUnstable)
                }),
            output: OutputRecord(
                file: mkv.lastPathComponent, bytes: bytes,
                audioTracks: title.audio.filter { selection?.audio.contains($0.number) ?? true }.map(\.description),
                subtitleTracks: title.subtitles.filter { selection?.subtitles.contains($0.number) ?? true }
                    .map(\.description),
                timestampDiscontinuities: remux.discontinuities, warnings: remux.warnings))
    }
}

extension Duration {
    var seconds: Double { Double(components.seconds) + Double(components.attoseconds) / 1e18 }
}
