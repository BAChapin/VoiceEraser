import Foundation

public enum PipelineStage: String, Sendable {
    case decoding
    case removingSpeech
    case encoding
}

public struct PipelineProgress: Sendable, Equatable {
    public var stage: PipelineStage
    /// Overall completion, 0...1.
    public var fraction: Double
    /// Zero-based audio track being worked on, and how many there are.
    public var track: Int
    public var trackCount: Int
}

/// Decodes every audio track of a file, removes speech with an engine, and
/// muxes the result with all other streams copied.
public struct SpeechRemovalPipeline: Sendable {
    public let tools: FFmpegTools

    /// Share of each track's progress spent decoding; the rest of the track's
    /// share is speech removal. Encoding (all tracks at once) gets
    /// `encodingShare` of the total.
    static let decodingShare = 0.1
    static let encodingShare = 0.08

    public init(tools: FFmpegTools) {
        self.tools = tools
    }

    /// Writes `media` without speech to `output`. The output's extension
    /// chooses the container. On failure or cancellation `output` is removed.
    public func run(
        media: MediaInfo,
        engine: any SpeechRemovalEngine,
        output: URL,
        progress: @escaping @Sendable (PipelineProgress) -> Void
    ) async throws {
        let audioStreams = media.audioStreams
        guard !audioStreams.isEmpty else { throw FFmpegError.noAudioStreams }
        let fileManager = FileManager.default
        let workDirectory = fileManager.temporaryDirectory.appending(path: "VoiceEraser-\(UUID().uuidString)", directoryHint: .isDirectory)
        try fileManager.createDirectory(at: workDirectory, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: workDirectory) }

        do {
            let encoders = try await tools.audioEncoders()
            let duration = media.effectiveDuration
            let trackCount = audioStreams.count
            let perTrack = (1 - Self.encodingShare) / Double(trackCount)
            var tracks: [ProcessedAudioTrack] = []

            for (trackIndex, stream) in audioStreams.enumerated() {
                let base = Double(trackIndex) * perTrack
                let report: @Sendable (PipelineStage, Double) -> Void = { stage, fraction in
                    let within = stage == .decoding
                        ? Self.decodingShare * fraction
                        : Self.decodingShare + (1 - Self.decodingShare) * fraction
                    progress(PipelineProgress(stage: stage, fraction: base + perTrack * within, track: trackIndex, trackCount: trackCount))
                }
                let track = try await process(
                    stream,
                    of: media,
                    engine: engine,
                    duration: duration,
                    workDirectory: workDirectory,
                    trackIndex: trackIndex,
                    report: report
                )
                tracks.append(track)
            }

            let plans = tracks.map {
                AudioEncodingPlan.make(for: $0.source, containerExtension: output.pathExtension, availableEncoders: encoders)
            }
            let reportEncoding: @Sendable (Double) -> Void = { fraction in
                progress(PipelineProgress(
                    stage: .encoding,
                    fraction: 1 - Self.encodingShare + Self.encodingShare * fraction,
                    track: trackCount - 1,
                    trackCount: trackCount
                ))
            }
            try await mux(media: media, tracks: tracks, plans: plans, output: output, duration: duration, report: reportEncoding)
        } catch {
            try? fileManager.removeItem(at: output)
            throw error
        }
    }

    private func process(
        _ stream: MediaStream,
        of media: MediaInfo,
        engine: any SpeechRemovalEngine,
        duration: Double?,
        workDirectory: URL,
        trackIndex: Int,
        report: @escaping @Sendable (PipelineStage, Double) -> Void
    ) async throws -> ProcessedAudioTrack {
        let decodedURL = workDirectory.appending(path: "track-\(trackIndex)-decoded.f32", directoryHint: .notDirectory)
        let processedURL = workDirectory.appending(path: "track-\(trackIndex)-processed.f32", directoryHint: .notDirectory)
        let channels = FFmpegCommands.decodedChannelCount(for: stream)

        report(.decoding, 0)
        let decode = FFmpegCommands.decodeArguments(input: media.url, stream: stream, sampleRate: engine.sampleRate, output: decodedURL)
        let result = try await ProcessRunner.run(tools.ffmpeg, arguments: decode) { line in
            if let seconds = FFmpegCommands.progressSeconds(fromLine: line), let duration, duration > 0 {
                report(.decoding, min(seconds / duration, 1))
            }
        }
        guard result.status == 0 else {
            throw FFmpegError.toolFailed(tool: "ffmpeg", status: result.status, message: result.standardErrorText)
        }

        report(.removingSpeech, 0)
        do {
            let input = try MappedPCMFile(readingFrom: decodedURL, channels: channels)
            let output = try MappedPCMFile(creating: processedURL, channels: channels, frameCount: input.frameCount)
            try await engine.removeSpeech(input: input, output: output) { fraction in
                report(.removingSpeech, min(max(fraction, 0), 1))
            }
        }
        // The decoded copy can be large (about 1.3 GB per stereo hour).
        try? FileManager.default.removeItem(at: decodedURL)
        report(.removingSpeech, 1)
        return ProcessedAudioTrack(source: stream, url: processedURL, sampleRate: engine.sampleRate, channels: channels)
    }

    /// Muxes, retrying with fewer copied stream kinds if the container
    /// rejects some (for example a timecode data track).
    private func mux(
        media: MediaInfo,
        tracks: [ProcessedAudioTrack],
        plans: [AudioEncodingPlan],
        output: URL,
        duration: Double?,
        report: @escaping @Sendable (Double) -> Void
    ) async throws {
        var lastFailure: Error?
        for policy in StreamCopyPolicy.allCases {
            report(0)
            let arguments = FFmpegCommands.muxArguments(input: media.url, media: media, tracks: tracks, plans: plans, policy: policy, output: output)
            let result = try await ProcessRunner.run(tools.ffmpeg, arguments: arguments) { line in
                if let seconds = FFmpegCommands.progressSeconds(fromLine: line), let duration, duration > 0 {
                    report(min(seconds / duration, 1))
                }
            }
            if result.status == 0 {
                report(1)
                return
            }
            lastFailure = FFmpegError.toolFailed(tool: "ffmpeg", status: result.status, message: result.standardErrorText)
            try? FileManager.default.removeItem(at: output)
            // Only stream-copy problems are worth retrying with fewer streams.
            if !media.streams.contains(where: { [MediaStream.Kind.data, .attachment, .subtitle].contains($0.kind) }) {
                break
            }
        }
        throw lastFailure ?? FFmpegError.toolFailed(tool: "ffmpeg", status: -1, message: "")
    }
}
