import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Group {
            switch model.state {
            case .idle:
                if let drive = model.drives.drives.first {
                    ContentUnavailableView {
                        Label("Insert a DVD", systemImage: "opticaldisc")
                    } description: {
                        Text("\(drive) is ready. You can also open an ISO image, VIDEO_TS folder or .dvdmedia bundle.")
                    } actions: {
                        Button("Open…") { model.isImporting = true }
                    }
                } else {
                    ContentUnavailableView {
                        Label("No DVD Drive", systemImage: "externaldrive.badge.xmark")
                    } description: {
                        Text("Connect a DVD drive, or open an ISO image, VIDEO_TS folder or .dvdmedia bundle.")
                    } actions: {
                        Button("Open…") { model.isImporting = true }
                    }
                }
            case .scanning:
                VStack(spacing: 12) {
                    ProgressView()
                    Text("Reading \(model.source?.displayName ?? "disc")…")
                    Text("The first read of an encrypted disc can take a minute while keys are retrieved.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            case let .failed(message, log):
                ContentUnavailableView {
                    Label("Couldn't Read Disc", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(message)
                    if !log.isEmpty {
                        Text(log.joined(separator: "\n"))
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                    }
                } actions: {
                    Button("Try Again") { model.rescan() }
                }
            case let .loaded(disc):
                DiscView(disc: disc)
            }
        }
        .frame(minWidth: 760, minHeight: 480)
        .alert("Can't Start Rip", isPresented: Binding(get: { model.alert != nil }, set: { if !$0 { model.alert = nil } })) {
            Button("OK") { model.alert = nil }
        } message: {
            Text(model.alert ?? "")
        }
        .task { model.start() }
        .onChange(of: model.drives.discs) { model.drivesChanged() }
        .fileImporter(isPresented: $model.isImporting,
                      allowedContentTypes: [UTType(filenameExtension: "iso") ?? .diskImage,
                                            UTType(filenameExtension: "dvdmedia") ?? .package, .folder]) { result in
            if case let .success(url) = result { model.open(.file(url)) }
        }
        .dropDestination(for: URL.self) { urls, _ in
            guard let url = urls.first else { return false }
            model.open(.file(url))
            return true
        }
    }
}
