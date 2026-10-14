import DiscCore
import SwiftUI

/// Placeholder root view for milestone 1: proves the Swift ⇄ C++ bridge and the
/// vendored libraries are linked. Replaced by the Disc / Rip / Reports UI later.
struct ContentView: View {
    private let versions = dc.libraryVersions()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("dvdForge")
                .font(.largeTitle.bold())
            Text("Insert a DVD to begin.")
                .foregroundStyle(.secondary)
            Divider()
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 4) {
                row("libdvdread", versions.libdvdread)
                row("libdvdcss", versions.libdvdcss)
                row("libavformat", versions.libavformat)
                row("libavcodec", versions.libavcodec)
            }
            .font(.callout.monospaced())
        }
        .padding(24)
        .frame(minWidth: 480, minHeight: 280, alignment: .topLeading)
    }

    private func row(_ name: String, _ version: std.string) -> some View {
        GridRow {
            Text(name).foregroundStyle(.secondary)
            Text(String(version))
        }
    }
}
