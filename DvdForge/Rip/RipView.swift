import AppKit
import SwiftUI

/// Progress and results for a rip in progress or just finished.
struct RipView: View {
    let session: RipSession

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if let info = session.info {
                    Label(info, systemImage: "info.circle")
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let notice = session.notice {
                    Label(notice, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
                ForEach(session.entries) { entry in
                    TitleRipView(entry: entry, stopRetrying: { session.stopRetrying() })
                }
            }
            .padding()
        }
    }
}

private struct TitleRipView: View {
    let entry: RipSession.Entry
    var stopRetrying: () -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text("Title \(entry.title.number)").font(.headline)
                Text(entry.title.duration.dvdFormatted).foregroundStyle(.secondary)
                Spacer()
                statusLabel
            }
            if case .reading = entry.status {
                ProgressView(value: entry.progress.passFraction)
                HStack {
                    Text(detailLine).font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                    Spacer()
                    if entry.progress.pass == .trim || entry.progress.pass == .scrape {
                        Button("Stop Retrying", action: stopRetrying)
                            .help("Finish now. Sectors still unread are left blank (a brief glitch in the video) and listed in the report; everything already read is kept.")
                    }
                }
                if let current = entry.progress.current, entry.progress.pass != .sweep || current.seconds >= 1 {
                    NowReading(current: current)
                }
            }
            if case let .remuxing(fraction) = entry.status {
                ProgressView(value: fraction)
            }
            if !entry.map.isEmpty {
                SectorMapView(cells: entry.map)
                    .frame(height: 72)
                MapLegend(progress: entry.progress)
            }
            if let range = entry.closeUpRange, !entry.closeUp.isEmpty {
                DamageCloseUp(cells: entry.closeUp, range: range, progress: entry.progress,
                              isReading: { if case .reading = entry.status { true } else { false } }())
            }
            if !entry.events.isEmpty {
                ActivityLog(events: entry.events)
            }
            if case let .finished(read, remux) = entry.status {
                ResultSummary(result: read, remux: remux)
            }
            if let reportError = entry.reportError {
                Label(reportError, systemImage: "exclamationmark.circle").font(.callout).foregroundStyle(.orange)
            }
        }
    }

    @ViewBuilder private var statusLabel: some View {
        switch entry.status {
        case .queued:
            Text("Queued").foregroundStyle(.secondary)
        case .reading:
            Text(passName).foregroundStyle(.secondary)
        case .remuxing:
            Text("Writing MKV…").foregroundStyle(.secondary)
        case let .finished(read, _):
            if read.bad == 0 && read.unstable == 0 {
                Label("Archived", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
            } else {
                Label("Archived with damage", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            }
        case let .failed(message):
            Label(message, systemImage: "xmark.octagon.fill").foregroundStyle(.red)
        case .cancelled:
            Label("Cancelled — will resume next time", systemImage: "pause.circle").foregroundStyle(.secondary)
        }
    }

    private var passName: String {
        switch entry.progress.pass {
        case .opening: "Opening disc…"
        case .sweep: "Reading"
        case .trim: "Narrowing down damaged areas"
        case .scrape: "Retrying damaged areas"
        case .verify: "Verifying"
        case .done: "Finishing…"
        }
    }

    private var detailLine: String {
        let p = entry.progress
        var parts: [String] = []
        if p.bytesPerSecond > 0 {
            let rate = Int64(p.bytesPerSecond).formatted(.byteCount(style: .file))
            parts.append("\(rate)/s")
            if p.pass == .sweep || p.pass == .verify {
                let remaining = Double(p.passTotal - p.passDone) * 2048 / p.bytesPerSecond
                parts.append("\(Duration.seconds(remaining).dvdFormatted) left in pass")
            }
        }
        if p.readErrors > 0 { parts.append("\(p.readErrors) read errors") }
        if p.pending > 0 { parts.append("\(p.pending.formatted()) sectors left to retry") }
        if p.repaired > 0 { parts.append("\(p.repaired) repaired") }
        return parts.joined(separator: " · ")
    }
}

/// The title's sectors as a grid of cells, coloured by state (like ddrescueview).
struct SectorMapView: View {
    let cells: [MapCell]
    var columns = 150

    var body: some View {
        Canvas { context, size in
            let rows = Int((Double(cells.count) / Double(columns)).rounded(.up))
            guard rows > 0 else { return }
            let w = size.width / CGFloat(columns)
            let h = size.height / CGFloat(rows)
            for (i, cell) in cells.enumerated() {
                let rect = CGRect(x: CGFloat(i % columns) * w, y: CGFloat(i / columns) * h,
                                  width: max(w - 1, 1), height: max(h - 1, 1))
                context.fill(Path(rect), with: .color(cell.color))
            }
        }
        .accessibilityLabel("Sector map")
    }
}

extension MapCell {
    var color: Color {
        switch self {
        case .untried: Color.secondary.opacity(0.2)
        case .good: .green
        case .pending: .yellow
        case .unstable: .orange
        case .bad: .red
        }
    }
}

private struct MapLegend: View {
    let progress: ReadSnapshot

    var body: some View {
        HStack(spacing: 14) {
            item(.good, "Good", progress.good)
            item(.pending, "Retrying", progress.pending)
            item(.unstable, "Unstable", progress.unstable)
            item(.bad, "Unreadable", progress.bad)
        }
        .font(.caption.monospacedDigit())
        .foregroundStyle(.secondary)
    }

    private func item(_ cell: MapCell, _ name: String, _ count: UInt64) -> some View {
        HStack(spacing: 4) {
            RoundedRectangle(cornerRadius: 2).fill(cell.color).frame(width: 10, height: 10)
            Text("\(name) \(count.formatted())")
        }
    }
}

private struct ResultSummary: View {
    let result: TitleReadResult
    let remux: TitleRemuxResult

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(summary).font(.callout)
            if !result.damage.isEmpty {
                Text("Damaged areas").font(.callout.bold())
                ForEach(result.damage, id: \.self) { range in
                    Text("• Chapter \(range.chapter), around \(range.start.dvdFormatted): \(range.sectorCount) sectors \(range.isUnstable ? "unstable" : "unreadable")")
                        .font(.callout.monospacedDigit())
                }
            }
            ForEach(remux.warnings, id: \.self) { warning in
                Label(warning, systemImage: "info.circle").font(.callout).foregroundStyle(.secondary)
            }
            if let url = remux.outputURL {
                HStack {
                    Text(url.lastPathComponent).font(.callout.monospaced()).textSelection(.enabled)
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                        .buttonStyle(.link)
                }
            }
        }
    }

    private var summary: String {
        var parts = ["\(result.totalSectors.formatted()) sectors"]
        parts.append(result.verifyRan ? "verified" : "not re-verified")
        if result.resumed { parts.append("resumed") }
        if result.stoppedRetrying { parts.append("retries stopped early") }
        if result.readErrors > 0 { parts.append("\(result.readErrors) read errors along the way") }
        if result.repaired > 0 { parts.append("\(result.repaired) sectors repaired by verification") }
        if result.bad > 0 { parts.append("\(result.bad) unreadable (zero-filled)") }
        if result.unstable > 0 { parts.append("\(result.unstable) unstable") }
        return parts.joined(separator: " · ")
    }
}

// MARK: - Live detail while the reader works on damage

/// What the drive is doing this moment, and why it may take a while.
private struct NowReading: View {
    let current: ReadSnapshot.CurrentRead

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            let last = current.sector + UInt64(current.count) - 1
            let sectors = current.count == 1 ? "sector \(current.sector.formatted())"
                : "sectors \(current.sector.formatted())–\(last.formatted())"
            Label("Reading \(sectors) · chapter \(current.chapter) at \(current.position.dvdFormatted)"
                  + (current.seconds >= 1 ? " · drive working for \(Duration.seconds(current.seconds).dvdFormatted)" : ""),
                  systemImage: current.seconds >= 10 ? "hourglass" : "opticaldisc")
                .font(.callout.monospacedDigit())
            if current.seconds >= 10 {
                Text("The drive is retrying this spot internally, which can take several minutes on a scratch. It has already been marked, so nothing is lost if the drive gives up or resets; dvdForge carries on as soon as the drive answers. If the drive stays stuck, unplugging it and plugging it back in ends the wait and the rip resumes by itself.")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// The damaged part of the title, zoomed in, with the read position marked.
private struct DamageCloseUp: View {
    let cells: [MapCell]
    let range: Range<UInt64>
    let progress: ReadSnapshot
    let isReading: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Damaged area close-up").font(.callout.bold())
            Canvas { context, size in
                let w = size.width / CGFloat(cells.count)
                for (i, cell) in cells.enumerated() {
                    context.fill(Path(CGRect(x: CGFloat(i) * w, y: 0, width: max(w, 1), height: size.height)),
                                 with: .color(cell.color))
                }
                if isReading, let current = progress.current, range.contains(current.sector) {
                    let x = CGFloat(current.sector - range.lowerBound) / CGFloat(range.count) * size.width
                    context.fill(Path(CGRect(x: x - 1.5, y: -2, width: 3, height: size.height + 4)), with: .color(.primary))
                }
            }
            .frame(height: 22)
            .clipShape(RoundedRectangle(cornerRadius: 3))
            .accessibilityLabel("Close-up of the damaged area")
            Text(caption).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
        }
    }

    private var caption: String {
        var parts = ["Sectors \(range.lowerBound.formatted())–\((range.upperBound - 1).formatted())"]
        if progress.pending > 0 { parts.append("\(progress.pending.formatted()) still to retry") }
        if progress.bad > 0 { parts.append("\(progress.bad.formatted()) unreadable") }
        if progress.unstable > 0 { parts.append("\(progress.unstable.formatted()) unstable") }
        if isReading, progress.current != nil { parts.append("▮ = drive position") }
        return parts.joined(separator: " · ")
    }
}

/// What the reader did and why, newest at the bottom.
private struct ActivityLog: View {
    let events: [RipEvent]
    @State private var expanded = true

    var body: some View {
        DisclosureGroup("Activity (\(events.count))", isExpanded: $expanded) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 3) {
                        ForEach(events.suffix(200)) { event in
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Text(event.date.formatted(date: .omitted, time: .standard))
                                    .foregroundStyle(.secondary)
                                Text(event.message)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            .font(.caption.monospacedDigit())
                            .id(event.id)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                }
                .frame(maxHeight: 140)
                .onChange(of: events.count) { proxy.scrollTo(events.last?.id, anchor: .bottom) }
                .onAppear { proxy.scrollTo(events.last?.id, anchor: .bottom) }
            }
        }
        .font(.callout)
    }
}
