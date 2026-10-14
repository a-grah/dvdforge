import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Group {
            switch model.state {
            case .idle:
                ContentUnavailableView {
                    Label("No Disc", systemImage: "opticaldisc")
                } description: {
                    Text("Insert a DVD, or open an ISO image or VIDEO_TS folder.")
                } actions: {
                    Button("Open…") { model.isImporting = true }
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
