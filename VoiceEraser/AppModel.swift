import AppKit
import Observation
import UniformTypeIdentifiers
import VoiceEraserKit

/// One file in the batch.
struct BatchItem: Identifiable, Equatable {
    enum Status: Equatable {
        /// Reading its media information.
        case probing
        /// Can be processed.
        case ready
        /// Waiting its turn in the running batch.
        case queued
        case processing
        /// Written to this URL (the original, when replacing).
        case done(URL)
        case failed(String)
    }

    let id = UUID()
    let url: URL
    var media: MediaInfo?
    var status: Status = .probing
    var progress: PipelineProgress?
}

/// State and actions for the main window: a list of files processed one
/// after another with the same settings.
@Observable
final class AppModel {
    private(set) var items: [BatchItem] = []
    private(set) var isRunning = false
    /// Shown before the first progress update of a run (for example while
    /// the Demucs model loads).
    private(set) var statusDetail: String?
    /// Outcome of the last finished run, for example "3 done, 1 failed".
    private(set) var lastRunSummary: String?
    var engineKind: SpeechRemovalEngineKind
    /// Whether to overwrite the original files. Only set to true after the
    /// user confirms (see `requestReplaceOriginal`).
    private(set) var replaceOriginal = false
    var isConfirmingReplace = false
    /// Where processed files go when not replacing originals.
    private(set) var outputFolder: URL?
    var errorMessage: String?

    let tools: FFmpegTools?
    let demucsModelURL: URL?
    let voiceIsolationAvailable: Bool

    private var runTask: Task<Void, Never>?
    private var runTotal = 0
    private var runFinished = 0
    private var demucsEngine: DemucsEngine?

    init() {
        tools = FFmpegTools.bundled() ?? FFmpegTools.fromEnvironment()
        demucsModelURL = DemucsEngine.bundledModelURL()
        voiceIsolationAvailable = VoiceIsolationEngine.isAvailable
        engineKind = demucsModelURL != nil ? .demucs : .appleVoiceIsolation
    }

    /// Files that a run would process.
    var readyCount: Int { items.filter { $0.status == .ready }.count }

    var hasFinishedItems: Bool {
        items.contains { item in
            switch item.status {
            case .done, .failed: true
            default: false
            }
        }
    }

    /// Completion of the running batch, 0...1.
    var overallFraction: Double {
        guard runTotal > 0 else { return 0 }
        let current = items.first { $0.status == .processing }?.progress?.fraction ?? 0
        return min((Double(runFinished) + current) / Double(runTotal), 1)
    }

    /// One-based position of the file being processed, and the run's size.
    var runPosition: (current: Int, total: Int) {
        (min(runFinished + 1, runTotal), runTotal)
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

    // MARK: - Adding and removing files

    func presentOpenPanel() {
        guard !isRunning else { return }
        let panel = NSOpenPanel()
        panel.title = "Add Video or Audio Files"
        panel.prompt = "Add"
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        // Any file: FFmpeg reads formats macOS has no type for (MKV, Opus…),
        // and unreadable files are marked as failed after probing.
        if panel.runModal() == .OK {
            add(panel.urls)
        }
    }

    /// Adds files, and the media files inside folders, that aren't already
    /// in the list, then reads their media information.
    func add(_ urls: [URL]) {
        guard !isRunning else { return }
        guard let tools else {
            errorMessage = FFmpegError.toolsMissing.localizedDescription
            return
        }
        let existing = Set(items.map { $0.url.standardizedFileURL })
        let newItems = MediaFileCollector.collect(urls)
            .filter { !existing.contains($0) }
            .map { BatchItem(url: $0) }
        guard !newItems.isEmpty else { return }
        items += newItems
        lastRunSummary = nil

        Task {
            for item in newItems {
                do {
                    let media = try await MediaProbe.probe(item.url, tools: tools)
                    guard !media.audioStreams.isEmpty else { throw FFmpegError.noAudioStreams }
                    update(item.id) {
                        $0.media = media
                        $0.status = .ready
                    }
                } catch {
                    update(item.id) { $0.status = .failed(Self.probeFailureMessage(error)) }
                }
            }
        }
    }

    func remove(_ id: BatchItem.ID) {
        guard !isRunning else { return }
        items.removeAll { $0.id == id }
    }

    func removeFinished() {
        guard !isRunning else { return }
        items.removeAll { item in
            switch item.status {
            case .done, .failed: true
            default: false
            }
        }
        lastRunSummary = nil
    }

    func removeAll() {
        guard !isRunning else { return }
        items.removeAll()
        lastRunSummary = nil
        replaceOriginal = false
    }

    /// Puts a finished or failed file back in line for the next run.
    func processAgain(_ id: BatchItem.ID) {
        guard !isRunning else { return }
        update(id) { item in
            if item.media != nil {
                item.status = .ready
                item.progress = nil
            }
        }
    }

    // MARK: - Replace toggle and output folder

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

    /// Asks for the output folder. Returns false if the user cancels.
    @discardableResult
    func chooseOutputFolder() -> Bool {
        let panel = NSOpenPanel()
        panel.title = "Choose Where to Save Processed Files"
        panel.prompt = "Choose"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = outputFolder ?? items.first?.url.deletingLastPathComponent()
        guard panel.runModal() == .OK, let url = panel.url else { return false }
        outputFolder = url
        return true
    }

    // MARK: - Processing

    func start() {
        guard !isRunning, let tools else { return }
        let targets = items.filter { $0.status == .ready }.map(\.id)
        guard !targets.isEmpty else { return }
        if !replaceOriginal, outputFolder == nil {
            guard chooseOutputFolder() else { return }
        }

        let settings = RunSettings(kind: engineKind, replacing: replaceOriginal, folder: outputFolder)
        for id in targets {
            update(id) { $0.status = .queued }
        }
        isRunning = true
        runTotal = targets.count
        runFinished = 0
        lastRunSummary = nil
        statusDetail = settings.kind == .demucs && demucsEngine == nil ? "Loading the Demucs model…" : "Starting…"
        runTask = Task { await run(targets, tools: tools, settings: settings) }
    }

    func cancel() {
        runTask?.cancel()
    }

    private struct RunSettings {
        var kind: SpeechRemovalEngineKind
        var replacing: Bool
        var folder: URL?
    }

    private func run(_ ids: [BatchItem.ID], tools: FFmpegTools, settings: RunSettings) async {
        var succeeded = 0
        var failed = 0
        var cancelled = false
        for id in ids {
            if Task.isCancelled {
                cancelled = true
                break
            }
            guard let media = items.first(where: { $0.id == id })?.media else { continue }
            update(id) {
                $0.status = .processing
                $0.progress = nil
            }
            do {
                let destination = try await process(media, id: id, tools: tools, settings: settings)
                update(id) {
                    $0.status = .done(destination)
                    $0.progress = nil
                }
                succeeded += 1
            } catch is CancellationError {
                update(id) {
                    $0.status = .ready
                    $0.progress = nil
                }
                cancelled = true
                break
            } catch {
                update(id) {
                    $0.status = .failed(error.localizedDescription)
                    $0.progress = nil
                }
                failed += 1
            }
            runFinished += 1
            statusDetail = nil
        }

        for index in items.indices where items[index].status == .queued {
            items[index].status = .ready
        }
        isRunning = false
        statusDetail = nil
        runTotal = 0
        runFinished = 0
        lastRunSummary = Self.summary(succeeded: succeeded, failed: failed, cancelled: cancelled)
    }

    /// Processes one file and puts the result in place; returns where it went.
    private func process(_ media: MediaInfo, id: BatchItem.ID, tools: FFmpegTools, settings: RunSettings) async throws -> URL {
        let output = try ScratchOutput(near: media.url)
        do {
            let engine = try await makeEngine(settings.kind)
            let throttle = ProgressThrottle()
            try await SpeechRemovalPipeline(tools: tools).run(media: media, engine: engine, output: output.url) { update in
                guard throttle.shouldReport(update) else { return }
                Task { @MainActor [weak self] in
                    self?.statusDetail = nil
                    self?.update(id) { item in
                        if item.status == .processing {
                            item.progress = update
                        }
                    }
                }
            }
            if settings.replacing {
                return try output.replace(media.url)
            }
            guard let folder = settings.folder else { throw CocoaError(.fileNoSuchFile) }
            let destination = OutputNaming.uniqueDestination(for: media.url, in: folder)
            try output.move(to: destination)
            return destination
        } catch {
            output.discard()
            throw error
        }
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

    // MARK: - Helpers

    private func update(_ id: BatchItem.ID, _ change: (inout BatchItem) -> Void) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        change(&items[index])
    }
}

extension AppModel {
    func showInFinder(_ urls: [URL]) {
        NSWorkspace.shared.activateFileViewerSelecting(urls)
    }

    var finishedURLs: [URL] {
        items.compactMap { item in
            switch item.status {
            case let .done(url): url
            default: nil
            }
        }
    }

    static func probeFailureMessage(_ error: Error) -> String {
        if let error = error as? FFmpegError, error == .noAudioStreams {
            return error.localizedDescription
        }
        return "Not a readable audio or video file."
    }

    static func summary(succeeded: Int, failed: Int, cancelled: Bool) -> String {
        var parts: [String] = []
        if succeeded > 0 { parts.append(succeeded == 1 ? "1 file done" : "\(succeeded) files done") }
        if failed > 0 { parts.append(failed == 1 ? "1 failed" : "\(failed) failed") }
        if cancelled { parts.append("cancelled") }
        return parts.isEmpty ? "Nothing was processed." : parts.joined(separator: ", ").capitalizedFirstLetter + "."
    }
}

private extension String {
    var capitalizedFirstLetter: String {
        prefix(1).uppercased() + dropFirst()
    }
}
