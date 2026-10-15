import SwiftUI

@main
struct DvdForgeApp: App {
    @State private var model = AppModel()
    @State private var updater = Updater.shared

    var body: some Scene {
        Window("dvdForge", id: "main") {
            ContentView()
                .environment(model)
        }
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button("About dvdForge") { AboutPanel.show() }
                Button("Check for Updates…") { updater.checkForUpdates() }
                    .disabled(!updater.canCheckForUpdates)
            }
            CommandGroup(replacing: .newItem) {
                Button("Open Disc Image or Folder…") { model.isImporting = true }
                    .keyboardShortcut("o")
            }
            CommandMenu("Disc") {
                Button("Rescan") { model.rescan() }
                    .keyboardShortcut("r")
                    .disabled(model.source == nil)
                Button("Eject") { model.eject() }
                    .keyboardShortcut("e")
                    .disabled(!model.isDriveSource)
                Divider()
                Button("Close Disc") { model.close() }
                    .keyboardShortcut("w", modifiers: [.command, .shift])
                    .disabled(model.source == nil)
            }
        }

        Window("Rip History", id: "history") {
            HistoryView()
        }
        .keyboardShortcut("y", modifiers: [.command, .shift])

        Settings {
            SettingsView()
        }
    }
}
