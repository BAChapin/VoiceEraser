import SwiftUI
import VoiceEraserKit

/// The open file: its details, the engine and replace settings, and the
/// current processing state.
struct FileDetailView: View {
    @Bindable var model: AppModel
    let media: MediaInfo

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            header
            Divider()
            settings
            Spacer(minLength: 0)
            footer
        }
        .padding(24)
        .alert("Replace the original file?", isPresented: $model.isConfirmingReplace) {
            Button("Replace Original", role: .destructive) { model.confirmReplaceOriginal() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("When processing finishes, VoiceEraser will overwrite “\(media.url.lastPathComponent)” with the speech-free version. This can't be undone.")
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: media.hasVideo ? "film" : "waveform")
                .font(.system(size: 34))
                .foregroundStyle(.tint)
                .frame(width: 44)
            VStack(alignment: .leading, spacing: 4) {
                Text(media.url.lastPathComponent)
                    .font(.title3.weight(.semibold))
                    .lineLimit(2)
                    .truncationMode(.middle)
                Text(MediaDescription.summary(of: media))
                    .foregroundStyle(.secondary)
                ForEach(media.audioStreams, id: \.index) { stream in
                    Text(MediaDescription.describe(stream))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            Button("Close", systemImage: "xmark.circle.fill") { model.closeFile() }
                .labelStyle(.iconOnly)
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .disabled(model.isBusy)
                .help("Close this file")
        }
    }

    private var settings: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Engine").font(.headline)
                Picker("Engine", selection: $model.engineKind) {
                    ForEach(SpeechRemovalEngineKind.allCases) { kind in
                        Text(kind.title)
                            .tag(kind)
                            .selectionDisabled(!model.isAvailable(kind))
                    }
                }
                .pickerStyle(.radioGroup)
                .labelsHidden()
                Text(model.unavailableReason(model.engineKind) ?? model.engineKind.summary)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: 6) {
                Toggle(
                    "Replace audio in the original file",
                    isOn: Binding(get: { model.replaceOriginal }, set: { model.requestReplaceOriginal($0) })
                )
                .toggleStyle(.switch)
                Text(model.replaceOriginal
                    ? "The original file will be overwritten when processing finishes."
                    : "You'll choose where to save the new file when processing finishes.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .disabled(model.isBusy)
    }

    @ViewBuilder
    private var footer: some View {
        switch model.phase {
        case .processing:
            ProcessingStatusView(progress: model.progress, detail: model.statusDetail) { model.cancel() }
        case .awaitingSave:
            HStack {
                Label("Speech removed. The file hasn't been saved yet.", systemImage: "checkmark.circle")
                Spacer()
                Button("Discard") { model.discardPendingOutput() }
                Button("Save…") { model.presentSavePanel() }
                    .buttonStyle(.borderedProminent)
            }
        case let .done(url, replacedOriginal):
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Label(
                        replacedOriginal ? "Original file updated." : "Saved “\(url.lastPathComponent)”.",
                        systemImage: "checkmark.circle.fill"
                    )
                    .foregroundStyle(.green)
                    Spacer()
                    Button("Show in Finder") { model.showInFinder(url) }
                }
                startButton(title: "Remove Speech Again")
            }
        default:
            startButton(title: "Remove Speech")
        }
    }

    private func startButton(title: String) -> some View {
        HStack {
            Spacer()
            Button(title) { model.start() }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
                .disabled(!model.isAvailable(model.engineKind))
        }
    }
}

struct ProcessingStatusView: View {
    var progress: PipelineProgress?
    var detail: String?
    var cancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title).font(.headline)
                Spacer()
                if let progress {
                    Text(progress.fraction, format: .percent.precision(.fractionLength(0)))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }
            if let progress {
                ProgressView(value: progress.fraction)
            } else {
                ProgressView().progressViewStyle(.linear)
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel, action: cancel)
                    .keyboardShortcut(.cancelAction)
            }
        }
    }

    private var title: String {
        guard let progress else { return detail ?? "Starting…" }
        let track = progress.trackCount > 1 ? " (track \(progress.track + 1) of \(progress.trackCount))" : ""
        return switch progress.stage {
        case .decoding: "Decoding audio\(track)…"
        case .removingSpeech: "Removing speech\(track)…"
        case .encoding: "Encoding…"
        }
    }
}

/// Human-readable media details.
enum MediaDescription {
    static func summary(of media: MediaInfo) -> String {
        var parts = [media.hasVideo ? "Video" : "Audio"]
        if let duration = media.effectiveDuration {
            parts.append(Duration.seconds(duration).formatted(.time(pattern: duration >= 3600 ? .hourMinuteSecond : .minuteSecond)))
        }
        let tracks = media.audioStreams.count
        parts.append(tracks == 1 ? "1 audio track" : "\(tracks) audio tracks")
        return parts.joined(separator: " · ")
    }

    static func describe(_ stream: MediaStream) -> String {
        var parts: [String] = []
        if let codec = stream.codecName { parts.append(codec.uppercased()) }
        if let layout = stream.channelLayout {
            parts.append(layout)
        } else if let channels = stream.channels {
            parts.append(channels == 1 ? "mono" : "\(channels) channels")
        }
        if let rate = stream.sampleRate {
            parts.append((Double(rate) / 1000).formatted(.number.precision(.fractionLength(0...1))) + " kHz")
        }
        if let bitRate = stream.bitRate {
            parts.append("\(bitRate / 1000) kbps")
        }
        return parts.joined(separator: ", ")
    }
}
