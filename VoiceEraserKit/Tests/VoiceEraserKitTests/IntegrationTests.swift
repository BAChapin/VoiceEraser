import Foundation
import Testing
@testable import VoiceEraserKit

/// End-to-end tests against real FFmpeg, Core ML, and Audio Unit code.
///
/// They need inputs that are built, not committed, so each is enabled only
/// when its input is present (CI provides all of them):
/// - `VOICEERASER_FFMPEG_DIR`: folder with `ffmpeg` and `ffprobe`
///   (Scripts/build-ffmpeg.sh output's `bin`).
/// - `VOICEERASER_MODEL`: `HTDemucsVocals.mlpackage` (Scripts/convert-model.py).
/// - `VOICEERASER_MODEL_REFERENCE`: the converter's `--reference-dir`.
enum TestEnvironment {
    static let tools = FFmpegTools.fromEnvironment()
    static let modelURL = path("VOICEERASER_MODEL")
    static let referenceDirectory = path("VOICEERASER_MODEL_REFERENCE")

    private static func path(_ name: String) -> URL? {
        guard let value = ProcessInfo.processInfo.environment[name], !value.isEmpty,
              FileManager.default.fileExists(atPath: value) else { return nil }
        return URL(filePath: value)
    }

    static func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "VoiceEraserTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Runs ffmpeg with `arguments` (after `-nostdin -hide_banner -y`).
    static func ffmpeg(_ arguments: [String]) async throws {
        let tools = try #require(tools)
        let result = try await ProcessRunner.run(tools.ffmpeg, arguments: ["-nostdin", "-hide_banner", "-loglevel", "error", "-y"] + arguments)
        #expect(result.status == 0, "ffmpeg failed: \(result.standardErrorText)")
    }

    /// Writes interleaved samples to a raw float32 file.
    static func writePCM(_ samples: [Float], channels: Int, to url: URL) throws -> MappedPCMFile {
        let file = try MappedPCMFile(creating: url, channels: channels, frameCount: samples.count / channels)
        for (index, sample) in samples.enumerated() {
            file.mutableSamples[index] = sample
        }
        return file
    }
}

/// Copies audio unchanged, so the pipeline's decode → mux path can be checked
/// on its own.
struct PassthroughEngine: SpeechRemovalEngine {
    var sampleRate = 44_100

    func removeSpeech(input: MappedPCMFile, output: MappedPCMFile, progress: @escaping @Sendable (Double) -> Void) async throws {
        let source = input.samples
        let destination = output.mutableSamples
        for index in source.indices {
            destination[index] = source[index]
        }
        progress(1)
    }
}

@Suite(.enabled(if: TestEnvironment.tools != nil, "needs VOICEERASER_FFMPEG_DIR"))
struct PipelineIntegrationTests {
    @Test func videoKeepsEveryStreamAndReencodesAudio() async throws {
        let tools = try #require(TestEnvironment.tools)
        let directory = try TestEnvironment.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let input = directory.appending(path: "clip.mov")
        try await TestEnvironment.ffmpeg([
            "-f", "lavfi", "-i", "testsrc=duration=2:size=160x120:rate=25",
            "-f", "lavfi", "-i", "sine=frequency=440:duration=2:sample_rate=48000",
            "-f", "lavfi", "-i", "sine=frequency=660:duration=2:sample_rate=44100",
            "-map", "0", "-map", "1", "-map", "2",
            "-c:v", "mpeg4", "-c:a", "aac", "-ac:a:0", "2", "-ac:a:1", "1",
            "-metadata:s:a:1", "language=fra",
            input.path(percentEncoded: false),
        ])

        let media = try await MediaProbe.probe(input, tools: tools)
        #expect(media.audioStreams.count == 2)
        let output = directory.appending(path: "out.mov")
        let updates = Updates()
        try await SpeechRemovalPipeline(tools: tools).run(media: media, engine: PassthroughEngine(), output: output) { updates.append($0) }

        let result = try await MediaProbe.probe(output, tools: tools)
        #expect(result.streams.map(\.kind) == media.streams.map(\.kind))
        #expect(result.streams[0].codecName == "mpeg4")
        #expect(result.audioStreams.map(\.codecName) == ["aac", "aac"])
        #expect(result.audioStreams.map(\.channels) == [2, 1])
        #expect(result.audioStreams.map(\.sampleRate) == [48_000, 44_100])
        #expect(abs((result.effectiveDuration ?? 0) - 2) < 0.1)
        let fractions = updates.values.map(\.fraction)
        #expect(abs((fractions.last ?? 0) - 1) < 1e-9)
        #expect(zip(fractions, fractions.dropFirst()).allSatisfy { $0 <= $1 + 1e-9 })
    }

    @Test(arguments: ["mp3", "flac", "wav", "m4a", "ogg"])
    func audioFormatsRoundTrip(_ ext: String) async throws {
        let tools = try #require(TestEnvironment.tools)
        let directory = try TestEnvironment.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let input = directory.appending(path: "tone.\(ext)")
        try await TestEnvironment.ffmpeg([
            "-f", "lavfi", "-i", "sine=frequency=440:duration=1.5:sample_rate=44100", "-ac", "2", "-strict", "experimental",
            input.path(percentEncoded: false),
        ])
        let media = try await MediaProbe.probe(input, tools: tools)
        let output = directory.appending(path: "out.\(ext)")
        try await SpeechRemovalPipeline(tools: tools).run(media: media, engine: PassthroughEngine(), output: output) { _ in }

        let result = try await MediaProbe.probe(output, tools: tools)
        #expect(result.audioStreams.first?.codecName == media.audioStreams.first?.codecName)
        #expect(result.audioStreams.first?.channels == 2)
        #expect(abs((result.effectiveDuration ?? 0) - 1.5) < 0.1)
    }

    @Test func fileWithoutAudioIsRejected() async throws {
        let tools = try #require(TestEnvironment.tools)
        let directory = try TestEnvironment.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let input = directory.appending(path: "silent.mov")
        try await TestEnvironment.ffmpeg(["-f", "lavfi", "-i", "testsrc=duration=1:size=64x64", "-c:v", "mpeg4", input.path(percentEncoded: false)])
        let media = try await MediaProbe.probe(input, tools: tools)
        await #expect(throws: FFmpegError.noAudioStreams) {
            try await SpeechRemovalPipeline(tools: tools).run(media: media, engine: PassthroughEngine(), output: directory.appending(path: "out.mov")) { _ in }
        }
    }

    @Test func replacingTheOriginalSwapsContents() throws {
        let directory = try TestEnvironment.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let original = directory.appending(path: "song.mp3")
        try Data("old".utf8).write(to: original)
        let scratch = try ScratchOutput(near: original)
        #expect(scratch.url.pathExtension == "mp3")
        try Data("new".utf8).write(to: scratch.url)
        try scratch.replace(original)
        #expect(try Data(contentsOf: original) == Data("new".utf8))
        #expect(!FileManager.default.fileExists(atPath: scratch.url.path(percentEncoded: false)))
    }
}

@Suite(.enabled(if: VoiceIsolationEngine.isAvailable, "needs the AUSoundIsolation audio unit"))
struct VoiceIsolationEngineTests {
    @Test func producesBoundedOutputOfTheSameLength() async throws {
        let directory = try TestEnvironment.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        var generator = SplitMix64(seed: 11)
        let frames = 48_000 * 2
        // Stereo: a tone in one channel, noise in the other.
        var samples = [Float](repeating: 0, count: frames * 2)
        for frame in 0..<frames {
            samples[frame * 2] = 0.3 * sin(2 * .pi * 220 * Float(frame) / 48_000)
            samples[frame * 2 + 1] = Float.random(in: -0.2...0.2, using: &generator)
        }
        let input = try TestEnvironment.writePCM(samples, channels: 2, to: directory.appending(path: "in.f32"))
        let output = try MappedPCMFile(creating: directory.appending(path: "out.f32"), channels: 2, frameCount: frames)
        try await VoiceIsolationEngine().removeSpeech(input: input, output: output) { _ in }

        #expect(output.frameCount == frames)
        let allFinite = output.samples.allSatisfy { $0.isFinite }
        #expect(allFinite)
        // A mask can only remove energy (up to window-overlap rounding).
        let inputEnergy = input.samples.reduce(0) { $0 + Double($1 * $1) }
        let outputEnergy = output.samples.reduce(0) { $0 + Double($1 * $1) }
        #expect(outputEnergy <= inputEnergy * 1.05)
    }

    @Test func lagEstimateFindsAKnownDelay() throws {
        let directory = try TestEnvironment.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        var generator = SplitMix64(seed: 5)
        let frames = 48_000
        let delay = 731
        let maximumLag = 12_000
        let mix = (0..<frames).map { _ in Float.random(in: -0.5...0.5, using: &generator) }
        var delayed = [Float](repeating: 0, count: frames + maximumLag)
        for index in 0..<frames {
            delayed[index + delay] = mix[index] * 0.5
        }
        let mixFile = try TestEnvironment.writePCM(mix, channels: 1, to: directory.appending(path: "mix.f32"))
        let voiceFile = try TestEnvironment.writePCM(delayed, channels: 1, to: directory.appending(path: "voice.f32"))
        let lag = VoiceIsolationEngine.estimateLag(mix: mixFile, channel: 0, voice: voiceFile, maximumLag: maximumLag, sampleRate: 48_000)
        #expect(lag == delay)
    }
}

@Suite(.enabled(if: TestEnvironment.modelURL != nil, "needs VOICEERASER_MODEL"))
struct DemucsEngineTests {
    static func loadEngine() async throws -> DemucsEngine {
        try await DemucsEngine.load(from: try #require(TestEnvironment.modelURL))
    }

    /// The Swift STFT + Core ML + iSTFT path reproduces PyTorch's vocals for
    /// the converter's reference segment.
    @Test(.enabled(if: TestEnvironment.referenceDirectory != nil, "needs VOICEERASER_MODEL_REFERENCE"))
    func separatedVocalsMatchPyTorch() async throws {
        let directory = try #require(TestEnvironment.referenceDirectory)
        let length = DemucsEngine.segmentLength
        let mix = try Self.planar(directory.appending(path: "reference-mix.f32"), length: length)
        let expected = try Self.planar(directory.appending(path: "reference-vocals.f32"), length: length)

        let engine = try await Self.loadEngine()
        let vocals = try await engine.separateVocals(left: mix[0], right: mix[1])
        for (actual, reference) in zip([vocals.left, vocals.right], expected) {
            let signal = reference.reduce(0) { $0 + Double($1 * $1) }
            let noise = zip(actual, reference).reduce(0) { $0 + Double(($1.0 - $1.1) * ($1.0 - $1.1)) }
            let snr = 10 * log10(signal / max(noise, 1e-20))
            #expect(snr > 20, "SNR \(snr) dB")
        }
    }

    @Test func removesSpeechFromAShortClip() async throws {
        let directory = try TestEnvironment.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        var generator = SplitMix64(seed: 3)
        let frames = 44_100 * 3
        // Mono exercises channel pairing; 3 s is shorter than one segment.
        let samples = (0..<frames).map { _ in Float.random(in: -0.3...0.3, using: &generator) }
        let input = try TestEnvironment.writePCM(samples, channels: 1, to: directory.appending(path: "in.f32"))
        let output = try MappedPCMFile(creating: directory.appending(path: "out.f32"), channels: 1, frameCount: frames)
        let updates = Updates()
        try await Self.loadEngine().removeSpeech(input: input, output: output) { updates.append(PipelineProgress(stage: .removingSpeech, fraction: $0, track: 0, trackCount: 1)) }
        let allFinite = output.samples.allSatisfy { $0.isFinite }
        #expect(allFinite)
        #expect(output.samples.contains { $0 != 0 })
        #expect(updates.values.last?.fraction == 1)
    }

    static func planar(_ url: URL, length: Int) throws -> [[Float]] {
        let data = try Data(contentsOf: url)
        let values = data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
        try #require(values.count == 2 * length)
        return [Array(values[0..<length]), Array(values[length...])]
    }
}

/// Collects progress updates from any thread.
final class Updates: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [PipelineProgress] = []

    var values: [PipelineProgress] { lock.withLock { stored } }

    func append(_ update: PipelineProgress) {
        lock.withLock { stored.append(update) }
    }
}
