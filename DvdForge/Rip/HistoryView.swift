import AppKit
import SwiftUI

/// Past rips, from the .dvdforge.json reports in the output folder.
struct HistoryView: View {
    @State private var reports: [RipReport] = []
    @State private var selection: RipReport.ID?
    @State private var loading = false
    @State private var folder = SettingsKey.outputFolderURL

    var body: some View {
        VSplitView {
            Group {
                if reports.isEmpty && !loading {
                    ContentUnavailableView("No Rips Yet", systemImage: "clock",
                                           description: Text("Reports of finished rips in \(folder.path) appear here."))
                } else {
                    table
                }
            }
            .frame(minHeight: 200)

            Group {
                if let report = reports.first(where: { $0.id == selection }) {
                    ReportDetail(report: report)
                } else {
                    Text("Select a rip to see how it went.")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(minHeight: 160)
        }
        .frame(minWidth: 720, minHeight: 460)
        .toolbar {
            ToolbarItem {
                Button("Reload", systemImage: "arrow.clockwise") { Task { await reload() } }
                    .keyboardShortcut("r")
            }
        }
        .task { await reload() }
    }

    private var table: some View {
        Table(reports, selection: $selection) {
            TableColumn("Date") { Text($0.date.formatted(date: .abbreviated, time: .shortened)) }
                .width(min: 120, ideal: 150)
            TableColumn("Disc") { Text($0.disc.label) }
            TableColumn("Title") { report in
                Text(report.title.isMainFeature ? "\(report.title.number) (main)" : "\(report.title.number)")
            }
            .width(70)
            TableColumn("Length") { Text(Duration.seconds($0.title.durationSeconds).dvdFormatted).monospacedDigit() }
                .width(70)
            TableColumn("Status") { report in
                if report.isClean {
                    Label("Clean", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                } else {
                    Label("\(report.read.unreadableSectors + report.read.unstableSectors) damaged sectors",
                          systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
            }
            .width(min: 120, ideal: 170)
        }
    }

    private func reload() async {
        loading = true
        folder = SettingsKey.outputFolderURL
        reports = await RipReport.loadAll(in: folder)
        loading = false
        if selection == nil { selection = reports.first?.id }
    }
}

private struct ReportDetail: View {
    let report: RipReport

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text(report.output.file).font(.headline).textSelection(.enabled)
                    Spacer()
                    if let mkv = report.mkvURL {
                        Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([mkv]) }
                    }
                }
                Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 4) {
                    row("Disc", "\(report.disc.label) · ID \(report.disc.id.prefix(8))")
                    if let drive = report.disc.drive { row("Drive", drive) }
                    row("Read", readSummary)
                    row("Size", report.output.bytes.formatted(.byteCount(style: .file)))
                    row("Audio", report.output.audioTracks.joined(separator: "\n"))
                    if !report.output.subtitleTracks.isEmpty {
                        row("Subtitles", report.output.subtitleTracks.joined(separator: "\n"))
                    }
                    row("Software", report.software)
                }
                .font(.callout)
                if !report.read.damage.isEmpty {
                    Text("Damaged areas").font(.callout.bold())
                    ForEach(report.read.damage, id: \.self) { d in
                        Text("• Chapter \(d.chapter), around \(Duration.seconds(d.startSeconds).dvdFormatted): \(d.sectors) sectors \(d.unstable ? "unstable" : "unreadable")")
                            .font(.callout.monospacedDigit())
                    }
                }
                ForEach(report.output.warnings, id: \.self) { warning in
                    Label(warning, systemImage: "info.circle").font(.callout).foregroundStyle(.secondary)
                }
                if let log = report.read.log, !log.isEmpty {
                    DisclosureGroup("Activity log (\(log.count))") {
                        Text(log.joined(separator: "\n"))
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .font(.callout)
                }
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var readSummary: String {
        let r = report.read
        var parts = [r.verifyRan ? "verified" : "single pass (verify: \(r.verifyMode))"]
        if r.resumed { parts.append("resumed") }
        if r.readErrors > 0 { parts.append("\(r.readErrors) read errors") }
        if r.repairedSectors > 0 { parts.append("\(r.repairedSectors) repaired") }
        if r.unreadableSectors > 0 { parts.append("\(r.unreadableSectors) unreadable") }
        if r.unstableSectors > 0 { parts.append("\(r.unstableSectors) unstable") }
        return parts.joined(separator: " · ")
    }

    private func row(_ label: String, _ value: String) -> some View {
        GridRow(alignment: .firstTextBaseline) {
            Text(label).foregroundStyle(.secondary)
            Text(value).textSelection(.enabled)
        }
    }
}
