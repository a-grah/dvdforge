import SwiftUI

/// Browses a loaded disc: title table on top, details of the focused title below.
struct DiscView: View {
    @Environment(AppModel.self) private var model
    let disc: Disc
    @State private var focusedTitle: DiscTitle.ID?
    @State private var showWarnings = false

    var body: some View {
        VSplitView {
            VStack(alignment: .leading, spacing: 0) {
                header
                Divider()
                titleTable
            }
            .frame(minHeight: 200)

            Group {
                if let rip = model.rip {
                    RipView(session: rip)
                } else if let title = disc.titles.first(where: { $0.id == focusedTitle }) {
                    TitleDetailView(title: title)
                } else {
                    Text("Select a title to see its chapters and tracks.")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(minHeight: 160)
        }
        .onAppear { focusedTitle = disc.mainFeature?.id ?? disc.titles.first?.id }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Image(systemName: "opticaldisc")
                .font(.title2)
            VStack(alignment: .leading, spacing: 2) {
                Text(disc.volumeLabel.isEmpty ? "Untitled Disc" : disc.volumeLabel)
                    .font(.title2.bold())
                Text(subtitle)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            Spacer()
            if !disc.warnings.isEmpty {
                Button {
                    showWarnings.toggle()
                } label: {
                    Label("\(disc.warnings.count) warning\(disc.warnings.count == 1 ? "" : "s")",
                          systemImage: "exclamationmark.triangle")
                }
                .buttonStyle(.borderless)
                .popover(isPresented: $showWarnings) {
                    ScrollView {
                        Text(disc.warnings.joined(separator: "\n"))
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                            .padding()
                    }
                    .frame(width: 420, height: 240)
                }
            }
            if model.isDriveSource {
                Button("Eject", systemImage: "eject") { model.eject() }
                    .disabled(model.isRipping)
            }
            ripButton
        }
        .padding()
    }

    @ViewBuilder private var ripButton: some View {
        if model.isRipping {
            Button("Cancel", role: .cancel) { model.cancelRip() }
        } else if model.rip != nil {
            Button("Done") { model.dismissRip() }
        } else {
            let count = model.selectedTitles.count
            Button(count > 1 ? "Rip \(count) Titles" : "Rip") { model.startRip() }
                .buttonStyle(.borderedProminent)
                .disabled(count == 0)
                .keyboardShortcut(.return, modifiers: .command)
        }
    }

    private var subtitle: String {
        var parts: [String] = []
        if case let .drive(drive) = model.source, let drive = drive.driveModel { parts.append(drive) }
        if case let .file(url) = model.source { parts.append(url.path) }
        parts.append("\(disc.titles.count) titles")
        parts.append("ID \(disc.discID.prefix(8))")
        return parts.joined(separator: " · ")
    }

    private var titleTable: some View {
        Table(disc.titles, selection: $focusedTitle) {
            TableColumn("Rip") { title in
                Toggle("Rip title \(title.number)", isOn: Binding(
                    get: { model.isTitleSelected(title.number) },
                    set: { model.setTitle(title.number, selected: $0) }))
                    .labelsHidden()
                    .disabled(model.rip != nil)
            }
            .width(32)
            TableColumn("Title") { title in
                HStack(spacing: 6) {
                    Text("\(title.number)").monospacedDigit()
                    if title.isMainFeature { Badge(text: "Main", tint: .accentColor) }
                    if title.isDuplicate { Badge(text: "Duplicate", tint: .secondary) }
                    if title.angles > 1 { Badge(text: "\(title.angles) angles", tint: .orange) }
                }
            }
            .width(min: 120, ideal: 160)
            TableColumn("Duration") { Text($0.duration.dvdFormatted).monospacedDigit() }
                .width(70)
            TableColumn("Chapters") { Text("\($0.chapters.count)").monospacedDigit() }
                .width(60)
            TableColumn("Video") { title in
                Text("\(title.width)×\(title.height) \(title.aspect.rawValue) \(title.isPAL ? "PAL" : "NTSC")")
            }
            .width(min: 120, ideal: 140)
            TableColumn("Audio") { title in
                Text(title.audio.map { "\($0.language.languageName) \($0.codec.rawValue) \($0.channelLayout)" }
                    .joined(separator: ", "))
                    .help(title.audio.map(\.description).joined(separator: "\n"))
            }
            TableColumn("Subtitles") { title in
                Text(title.subtitles.map(\.language.languageName).joined(separator: ", "))
            }
            TableColumn("Size") { Text($0.byteCount.formatted(.byteCount(style: .file))).monospacedDigit() }
                .width(70)
        }
    }
}

struct TitleDetailView: View {
    @Environment(AppModel.self) private var model
    let title: DiscTitle

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            GroupBox("Chapters") {
                List(title.chapters) { chapter in
                    HStack {
                        Text("Chapter \(chapter.number)")
                        Spacer()
                        Text(chapter.start.dvdFormatted).monospacedDigit().foregroundStyle(.secondary)
                    }
                }
                .listStyle(.plain)
            }
            GroupBox("Audio") {
                trackList(title.audio, isOn: { model.isAudioSelected(title: title.number, track: $0.number) },
                          set: { model.setAudio(title: title.number, track: $0.number, selected: $1) })
            }
            GroupBox("Subtitles") {
                trackList(title.subtitles,
                          isOn: { model.isSubtitleSelected(title: title.number, track: $0.number) },
                          set: { model.setSubtitle(title: title.number, track: $0.number, selected: $1) })
            }
        }
        .padding()
    }

    @ViewBuilder
    private func trackList<Track: Identifiable & CustomStringConvertible>(
        _ tracks: [Track], isOn: @escaping (Track) -> Bool, set: @escaping (Track, Bool) -> Void
    ) -> some View {
        if tracks.isEmpty {
            Text("None").foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            List(tracks) { track in
                Toggle(track.description, isOn: Binding(get: { isOn(track) }, set: { set(track, $0) }))
            }
            .listStyle(.plain)
        }
    }
}

private struct Badge: View {
    let text: String
    let tint: Color

    var body: some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .foregroundStyle(tint)
            .background(tint.opacity(0.15), in: Capsule())
    }
}

// MARK: - Formatting

extension Duration {
    /// "1:32:05" or "4:07".
    var dvdFormatted: String {
        let total = Int((Double(components.seconds) + Double(components.attoseconds) / 1e18).rounded())
        let (h, m, s) = (total / 3600, total / 60 % 60, total % 60)
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }
}

extension String {
    /// "en" → "English"; empty → "Unknown".
    var languageName: String {
        isEmpty ? "Unknown" : Locale.current.localizedString(forLanguageCode: self) ?? self
    }
}

extension AudioTrackInfo: CustomStringConvertible {
    var description: String {
        var s = "\(number + 1). \(language.languageName) — \(codec.rawValue) \(channelLayout), \(sampleRate / 1000) kHz"
        if bitsPerSample > 0 { s += ", \(bitsPerSample)-bit" }
        if purpose != .normal { s += " (\(purpose.rawValue))" }
        return s
    }
}

extension SubtitleTrackInfo: CustomStringConvertible {
    var description: String {
        var s = "\(number + 1). \(language.languageName)"
        if purpose != .normal { s += " (\(purpose.rawValue))" }
        return s
    }
}
