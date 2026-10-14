import SwiftUI

struct SettingsView: View {
    @AppStorage(SettingsKey.verifyRead) private var verifyRead = VerifyRead.auto
    @AppStorage(SettingsKey.retries) private var retries = 8
    @AppStorage(SettingsKey.outputFolder) private var outputFolder = SettingsKey.defaultOutputFolder.path
    @AppStorage(SettingsKey.keepStaging) private var keepStaging = false
    @AppStorage(SettingsKey.preferredLanguages) private var languages = TrackPreferences.systemLanguage
    @AppStorage(SettingsKey.audioTracks) private var audioTracks = TrackChoice.all
    @AppStorage(SettingsKey.subtitleTracks) private var subtitleTracks = TrackChoice.all
    @AppStorage(SettingsKey.autoRip) private var autoRip = false
    @AppStorage(SettingsKey.ejectWhenDone) private var ejectWhenDone = false
    @State private var choosingFolder = false

    var body: some View {
        Form {
            Section {
                Picker("Verify read", selection: $verifyRead) {
                    ForEach(VerifyRead.allCases) { Text($0.label).tag($0) }
                }
                Text("Verification re-reads the whole title and compares, catching drives that return wrong data without reporting an error. It roughly doubles rip time. Auto runs it only when the disc produced read errors.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Stepper("Retry rounds for damaged areas: \(retries)", value: $retries, in: 1 ... 64)
            } header: {
                Text("Reading")
            }
            Section {
                TextField("Preferred languages", text: $languages, prompt: Text("en, fr"))
                Picker("Audio tracks", selection: $audioTracks) {
                    Text("All").tag(TrackChoice.all)
                    Text("Preferred languages only").tag(TrackChoice.preferred)
                }
                Picker("Subtitles", selection: $subtitleTracks) {
                    Text("All").tag(TrackChoice.all)
                    Text("Preferred languages only").tag(TrackChoice.preferred)
                    Text("None").tag(TrackChoice.none)
                }
                Text("Two-letter codes in order of preference. They pre-select tracks when a disc is loaded (you can still change them per title) and choose the MKV's default audio track. A title with no audio in your languages keeps all of its audio.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } header: {
                Text("Languages")
            }
            OnlineLookupSettings()
            Section {
                Toggle("Rip the main feature as soon as a disc is inserted", isOn: $autoRip)
                Toggle("Eject the disc when the rip finishes", isOn: $ejectWhenDone)
                Text("Together these turn archiving a stack of discs into: insert, wait for the chime, swap.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } header: {
                Text("Batch")
            }
            Section {
                LabeledContent("Save MKVs to") {
                    HStack {
                        Text(URL(filePath: outputFolder).abbreviatedPath)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Button("Choose…") { choosingFolder = true }
                    }
                }
                Toggle("Keep staging files after a successful rip", isOn: $keepStaging)
                Text("Staging files are the raw title data read from the disc (several GB each). Keeping them lets you re-run the MKV step without the disc.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } header: {
                Text("Output")
            }
        }
        .formStyle(.grouped)
        .fileImporter(isPresented: $choosingFolder, allowedContentTypes: [.folder]) { result in
            if case let .success(url) = result { outputFolder = url.path }
        }
        .frame(width: 460)
    }
}

private extension URL {
    /// "/Users/me/Movies/dvdForge" → "~/Movies/dvdForge".
    var abbreviatedPath: String { (path as NSString).abbreviatingWithTildeInPath }
}
