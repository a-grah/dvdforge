import SwiftUI

struct SettingsView: View {
    @AppStorage(SettingsKey.verifyRead) private var verifyRead = VerifyRead.auto
    @AppStorage(SettingsKey.retries) private var retries = 8

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
        }
        .formStyle(.grouped)
        .frame(width: 460)
    }
}
