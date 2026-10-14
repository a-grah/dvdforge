import SwiftUI

struct SettingsView: View {
    @AppStorage(SettingsKey.verifyRead) private var verifyRead = VerifyRead.auto
    @AppStorage(SettingsKey.retries) private var retries = 8
    @AppStorage(SettingsKey.outputFolder) private var outputFolder = SettingsKey.defaultOutputFolder.path
    @AppStorage(SettingsKey.keepStaging) private var keepStaging = false
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
                Stepper("Retries per damaged sector: \(retries)", value: $retries, in: 1 ... 64)
            } header: {
                Text("Reading")
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
