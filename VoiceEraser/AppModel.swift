import AppKit
import Observation
import UniformTypeIdentifiers
import VoiceEraserKit

/// State and actions for the main window.
@Observable
final class AppModel {
    enum Phase: Equatable {
        /// No file open.
        case empty
        /// Reading the file's media information.
        case loading(URL)
        /// File open and ready to process.
        case ready
        case processing
        /// Finished, waiting for the user to pick where to save.
        case awaitingSave
        /// Finished and written to `url`.
        case done(url: URL, replacedOriginal: Bool)
    }

    private(set) var phase: Phase = .empty
    private(set) var media: MediaInfo?
    private(set) var progress: PipelineProgress?
    private(set) var statusDetail: String?
    var engineKind: SpeechRemovalEngineKind
    /// Whether to overwrite the original file. Only set to true after the
    /// user confirms (see `requestReplaceOriginal`).
    private(set) var replaceOriginal = false
    var isConfirmingReplace = false
    var errorMessage: String?

    let tools: FFmpegTools?
    let demucsModelURL: URL?
    let voiceIsolationAvailable: Bool

    private var pendingOutput: ScratchOutput?
    private var task: Task<Void, Never>?
    private var demucsEngine: DemucsEngine?

    init() {
        tools = FFmpegTools.bundled() ?? FFmpegTools.fromEnvironment()
        demucsModelURL = DemucsEngine.bundledModelURL()
        voiceIsolationAvailable = VoiceIsolationEngine.isAvailable
        engineKind = demucsModelURL != nil ? .demucs : .appleVoiceIsolation
    }

    var fileURL: URL? { media?.url }

    var isBusy: Bool {
        switch phase {
        case .loading, .processing: true
        default: false
        }
    }

    func isAvailable(_ kind: SpeechRemovalEngineKind) -> Bool {
        switch kind {
        case .demucs: demucsModelURL != nil
        case .appleVoiceIsolation: voiceIsolationAvailable
        }
    }

    func unavailableReason(_ kind: SpeechRemovalEngineKind) -> String? {
        guard !isAvailable(kind) else { return nil }
        return switch kind {
        case .demucs: "The Demucs model isn't included in this build."
        case .appleVoiceIsolation: "Voice Isolation isn't available on this Mac."
        }
    }

    // MARK: - Opening

    func presentOpenPanel() {
        guard !isBusy else { return }
        let panel = NSOpenPanel()
        panel.title = "Choose a Video or Audio File"
        panel.prompt = "Open"
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        // Any file: FFmpeg reads formats macOS has no type for (MKV, Opus…),
        // and unreadable files get a clear error after probing.
        if panel.runModal() == .OK, let url = panel.url {
            open(url)
        }
    }

    func open(_ url: URL) {
        guard !isBusy else { return }
        guard let tools else {
            errorMessage = FFmpegError.toolsMissing.localizedDescription
            return
        }
        discardPendingOutput()
        replaceOriginal = false
        progress = nil
        statusDetail = nil
        phase = .loading(url)
        task = Task {
            do {
                let info = try await MediaProbe.probe(url, tools: tools)
                guard !info.audioStreams.isEmpty else { throw FFmpegError.noAudioStreams }
                media = info
                phase = .ready
            } catch {
                media = nil
                phase = .empty
                errorMessage = "Couldn't open “\(url.lastPathComponent)”. \(error.localizedDescription)"
            }
        }
    }

    func closeFile() {
        guard !isBusy else { return }
        discardPendingOutput()
        media = nil
        progress = nil
        replaceOriginal = false
        phase = .empty
    }

    // MARK: - Replace toggle

    /// The toggle's setter: turning it on asks for confirmation first.
    func requestReplaceOriginal(_ enabled: Bool) {
        if enabled {
            isConfirmingReplace = true
        } else {
            replaceOriginal = false
        }
    }

    func confirmReplaceOriginal() {
        replaceOriginal = true
    }

    // MARK: - Processing

    func start() {
        guard let media, let tools, !isBusy else { return }
        discardPendingOutput()
        let replacing = replaceOriginal
        let kind = engineKind
        phase = .processing
        progress = nil
        statusDetail = kind == .demucs && demucsEngine == nil ? "Loading the Demucs model…" : "Starting…"

        task = Task {
            var scratch: ScratchOutput?
            do {
                let output = try ScratchOutput(near: media.url)
                scratch = output
                let engine = try await makeEngine(kind)
                let throttle = ProgressThrottle()
                try await SpeechRemovalPipeline(tools: tools).run(media: media, engine: engine, output: output.url) { update in
                    guard throttle.shouldReport(update) else { return }
                    Task { @MainActor [weak self] in
                        guard let self, self.phase == .processing else { return }
                        self.progress = update
                        self.statusDetail = nil
                    }
                }
                if replacing {
                    let url = try output.replace(media.url)
                    phase = .done(url: url, replacedOriginal: true)
                } else {
                    pendingOutput = output
                    phase = .awaitingSave
                    presentSavePanel()
                }
            } catch is CancellationError {
                scratch?.discard()
                phase = .ready
            } catch {
                scratch?.discard()
                phase = .ready
                errorMessage = error.localizedDescription
            }
            progress = nil
            statusDetail = nil
        }
    }

    func cancel() {
        task?.cancel()
    }

    private func makeEngine(_ kind: SpeechRemovalEngineKind) async throws -> any SpeechRemovalEngine {
        switch kind {
        case .demucs:
            if let demucsEngine { return demucsEngine }
            guard let demucsModelURL else { throw SpeechRemovalError.modelMissing }
            let engine = try await DemucsEngine.load(from: demucsModelURL)
            demucsEngine = engine
            return engine
        case .appleVoiceIsolation:
            guard voiceIsolationAvailable else { throw SpeechRemovalError.voiceIsolationUnavailable }
            return VoiceIsolationEngine()
        }
    }

    // MARK: - Saving

    func presentSavePanel() {
        guard let pendingOutput, let original = media?.url else { return }
        let panel = NSSavePanel()
        panel.title = "Save Without Speech"
        panel.nameFieldStringValue = ScratchOutput.suggestedFileName(for: original)
        panel.directoryURL = original.deletingLastPathComponent()
        panel.canCreateDirectories = true
        if let type = UTType(filenameExtension: original.pathExtension) {
            panel.allowedContentTypes = [type]
        }
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        do {
            try pendingOutput.move(to: destination)
            self.pendingOutput = nil
            phase = .done(url: destination, replacedOriginal: false)
        } catch {
            errorMessage = "Couldn't save “\(destination.lastPathComponent)”. \(error.localizedDescription)"
        }
    }

    func discardPendingOutput() {
        pendingOutput?.discard()
        pendingOutput = nil
        if phase == .awaitingSave {
            phase = .ready
        }
    }

    func showInFinder(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }
}
