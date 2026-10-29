import SwiftUI
import VoiceEraserKit

struct ContentView: View {
    @Bindable var model: AppModel
    @State private var isDropTargeted = false

    var body: some View {
        Group {
            switch model.phase {
            case .empty:
                DropZoneView(isTargeted: isDropTargeted) { model.presentOpenPanel() }
            case let .loading(url):
                ProgressView("Reading “\(url.lastPathComponent)”…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .ready, .processing, .awaitingSave, .done:
                if let media = model.media {
                    FileDetailView(model: model, media: media)
                }
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            guard let url = urls.first, !model.isBusy else { return false }
            model.open(url)
            return true
        } isTargeted: { isDropTargeted = $0 }
        .alert(
            "Something went wrong",
            isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } }),
            presenting: model.errorMessage
        ) { _ in
            Button("OK") { model.errorMessage = nil }
        } message: { message in
            Text(message)
        }
        .overlay {
            if model.tools == nil {
                ContentUnavailableView(
                    "FFmpeg Is Missing",
                    systemImage: "exclamationmark.triangle",
                    description: Text("This build of VoiceEraser doesn't include FFmpeg. Build it with Scripts/build-ffmpeg.sh and rebuild the app.")
                )
                .background(.background)
            }
        }
    }
}

struct DropZoneView: View {
    var isTargeted: Bool
    var choose: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "waveform.badge.minus")
                .font(.system(size: 56, weight: .light))
                .foregroundStyle(isTargeted ? Color.accentColor : .secondary)
            Text("Drop a video or audio file here")
                .font(.title3)
            Text("VoiceEraser removes speech and keeps music, ambience, and effects.")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("Choose File…", action: choose)
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background {
            RoundedRectangle(cornerRadius: 16)
                .strokeBorder(style: StrokeStyle(lineWidth: 2, dash: [8, 6]))
                .foregroundStyle(isTargeted ? Color.accentColor : Color.secondary.opacity(0.4))
                .padding(20)
        }
    }
}
