import SwiftUI
import VoiceEraserKit

/// The batch: the list of files, the settings that apply to all of them, and
/// the run controls.
struct BatchView: View {
    @Bindable var model: AppModel
    var isDropTargeted: Bool

    var body: some View {
        VStack(spacing: 0) {
            List {
                ForEach(model.items) { item in
                    BatchItemRow(item: item, model: model)
                }
            }
            .listStyle(.inset(alternatesRowBackgrounds: true))
            .overlay {
                if isDropTargeted {
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(Color.accentColor, lineWidth: 3)
                        .padding(4)
                }
            }

            Divider()

            VStack(alignment: .leading, spacing: 16) {
                settings
                Divider()
                footer
            }
            .padding(20)
        }
        .alert("Replace the original files?", isPresented: $model.isConfirmingReplace) {
            Button("Replace Originals", role: .destructive) { model.confirmReplaceOriginal() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("""
            When a file finishes processing, VoiceEraser will overwrite the original with the speech-free version. \
            This applies to every file in the list, including files you add later, and can't be undone.
            """)
        }
    }

    private var settings: some View {
        HStack(alignment: .top, spacing: 32) {
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
            .frame(maxWidth: .infinity, alignment: .leading)

            VStack(alignment: .leading, spacing: 8) {
                Text("Output").font(.headline)
                Toggle(
                    "Replace audio in the original files",
                    isOn: Binding(get: { model.replaceOriginal }, set: { model.requestReplaceOriginal($0) })
                )
                .toggleStyle(.switch)
                if model.replaceOriginal {
                    Text("Each original file is overwritten when it finishes.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } else {
                    HStack(spacing: 6) {
                        Image(systemName: "folder")
                            .foregroundStyle(.secondary)
                        Text(model.outputFolder?.lastPathComponent ?? "Choose a folder when you start")
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .foregroundStyle(model.outputFolder == nil ? .secondary : .primary)
                            .help(model.outputFolder?.path(percentEncoded: false) ?? "")
                        Button("Choose…") { model.chooseOutputFolder() }
                            .controlSize(.small)
                    }
                    Text("Saved as “<name> (No Speech)”; existing files are never overwritten.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .disabled(model.isRunning)
    }

    @ViewBuilder
    private var footer: some View {
        if model.isRunning {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(runTitle).font(.headline)
                    Spacer()
                    Text(model.overallFraction, format: .percent.precision(.fractionLength(0)))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                ProgressView(value: model.overallFraction)
                HStack {
                    Spacer()
                    Button("Cancel", role: .cancel) { model.cancel() }
                        .keyboardShortcut(.cancelAction)
                }
            }
        } else {
            HStack(spacing: 12) {
                Button("Add Files…", systemImage: "plus") { model.presentOpenPanel() }
                Menu("Remove") {
                    Button("Remove Finished") { model.removeFinished() }
                        .disabled(!model.hasFinishedItems)
                    Button("Remove All") { model.removeAll() }
                }
                .fixedSize()
                if let summary = model.lastRunSummary {
                    Text(summary)
                        .foregroundStyle(.secondary)
                    if !model.finishedURLs.isEmpty {
                        Button("Show in Finder") { model.showInFinder(model.finishedURLs) }
                    }
                }
                Spacer()
                Button(startTitle) { model.start() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .keyboardShortcut(.defaultAction)
                    .disabled(model.readyCount == 0 || !model.isAvailable(model.engineKind))
            }
        }
    }

    private var startTitle: String {
        model.readyCount == 1 ? "Remove Speech from 1 File" : "Remove Speech from \(model.readyCount) Files"
    }

    private var runTitle: String {
        let position = model.runPosition
        let detail = model.statusDetail.map { " — \($0)" } ?? ""
        return "Processing file \(position.current) of \(position.total)\(detail)"
    }
}

/// One file in the batch list.
struct BatchItemRow: View {
    let item: BatchItem
    let model: AppModel

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: item.media?.hasVideo == true ? "film" : "waveform")
                .font(.title2)
                .foregroundStyle(.tint)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.url.lastPathComponent)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(detail)
                    .font(.callout)
                    .foregroundStyle(isFailed ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
                    .lineLimit(2)
            }
            Spacer(minLength: 12)
            status
            if !model.isRunning {
                Button("Remove", systemImage: "xmark.circle.fill") { model.remove(item.id) }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help("Remove from the list")
            }
        }
        .padding(.vertical, 4)
        .contextMenu {
            if case let .done(url) = item.status {
                Button("Show in Finder") { model.showInFinder([url]) }
            }
            if canProcessAgain {
                Button("Process Again") { model.processAgain(item.id) }
            }
            Button("Remove") { model.remove(item.id) }
                .disabled(model.isRunning)
        }
    }

    @ViewBuilder
    private var status: some View {
        switch item.status {
        case .probing:
            ProgressView().controlSize(.small)
        case .ready:
            EmptyView()
        case .queued:
            Text("Waiting").foregroundStyle(.secondary)
        case .processing:
            VStack(alignment: .trailing, spacing: 4) {
                if let progress = item.progress {
                    ProgressView(value: progress.fraction)
                        .frame(width: 140)
                } else {
                    ProgressView()
                        .progressViewStyle(.linear)
                        .frame(width: 140)
                }
                Text(stageText).font(.caption).foregroundStyle(.secondary)
            }
        case let .done(url):
            HStack(spacing: 6) {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                Button("Show in Finder", systemImage: "magnifyingglass") { model.showInFinder([url]) }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .help("Show “\(url.lastPathComponent)” in Finder")
            }
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
        }
    }

    private var detail: String {
        switch item.status {
        case let .failed(message):
            message
        case let .done(url):
            url == item.url ? "Original replaced" : "Saved as “\(url.lastPathComponent)”"
        default:
            item.media.map(MediaDescription.summary(of:)) ?? "Reading…"
        }
    }

    private var stageText: String {
        guard let progress = item.progress else { return "Starting…" }
        let track = progress.trackCount > 1 ? " (track \(progress.track + 1) of \(progress.trackCount))" : ""
        return switch progress.stage {
        case .decoding: "Decoding\(track)"
        case .removingSpeech: "Removing speech\(track)"
        case .encoding: "Encoding"
        }
    }

    private var isFailed: Bool {
        switch item.status {
        case .failed: true
        default: false
        }
    }

    private var canProcessAgain: Bool {
        guard !model.isRunning, item.media != nil else { return false }
        switch item.status {
        case .done, .failed: return true
        default: return false
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
        if let first = media.audioStreams.first {
            parts.append(describe(first))
        }
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
