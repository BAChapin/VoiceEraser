import Accelerate
import AudioToolbox
import AVFoundation
import Foundation

/// Fast speech removal with Apple's Voice Isolation audio unit
/// (`AUSoundIsolation`).
///
/// For each channel: render the channel through the audio unit to estimate
/// the speech, find the unit's delay by cross-correlating its output with the
/// input, then remove the speech from the mix with a spectral mask
/// `max(0, 1 − |speech| / |mix|)`. A mask (rather than subtraction) tolerates
/// the phase changes the audio unit makes.
public final class VoiceIsolationEngine: SpeechRemovalEngine, @unchecked Sendable {
    public let sampleRate = 48_000
    static let renderBlockSize = 4096
    /// Longest delay between input and isolated voice that the alignment
    /// search considers.
    static let maximumLagSeconds = 0.25
    static let correlationWindowSeconds = 3.0

    static let componentDescription = AudioComponentDescription(
        componentType: kAudioUnitType_Effect,
        componentSubType: kAudioUnitSubType_AUSoundIsolation,
        componentManufacturer: kAudioUnitManufacturer_Apple,
        componentFlags: 0,
        componentFlagsMask: 0
    )

    public init() {}

    /// Whether this Mac has the Voice Isolation audio unit.
    public static var isAvailable: Bool {
        var description = componentDescription
        return AudioComponentFindNext(nil, &description) != nil
    }

    public func removeSpeech(
        input: MappedPCMFile,
        output: MappedPCMFile,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws {
        guard Self.isAvailable else { throw SpeechRemovalError.voiceIsolationUnavailable }
        let frames = input.frameCount
        guard frames > 0 else { return }
        let maximumLag = Int(Self.maximumLagSeconds * Double(sampleRate))
        let voiceURL = FileManager.default.temporaryDirectory
            .appending(path: "voiceeraser-voice-\(UUID().uuidString).f32", directoryHint: .notDirectory)
        defer { try? FileManager.default.removeItem(at: voiceURL) }

        let channels = Double(input.channels)
        for channel in 0..<input.channels {
            try Task.checkCancellation()
            let isolator = try VoiceIsolator(sampleRate: Double(sampleRate), blockSize: Self.renderBlockSize)
            let voice = try MappedPCMFile(creating: voiceURL, channels: 1, frameCount: frames + maximumLag + isolator.latencyFrames)
            try isolator.render(channel: channel, of: input, into: voice) { fraction in
                progress((Double(channel) + 0.8 * fraction) / channels)
            }
            let lag = Self.estimateLag(mix: input, channel: channel, voice: voice, maximumLag: maximumLag, sampleRate: sampleRate)
                ?? isolator.latencyFrames
            try Task.checkCancellation()
            SpectralMask(fftSize: 2048, hopSize: 512).apply(mix: input, channel: channel, voice: voice, lag: lag, output: output)
            progress(Double(channel + 1) / channels)
        }
        output.synchronize()
    }

    /// The delay (in frames) of the isolated voice relative to the mix: the
    /// lag that maximizes their cross-correlation over the window where the
    /// voice is loudest. `nil` if there is too little speech to tell.
    static func estimateLag(mix: MappedPCMFile, channel: Int, voice: MappedPCMFile, maximumLag: Int, sampleRate: Int) -> Int? {
        let frames = mix.frameCount
        let window = min(frames, Int(correlationWindowSeconds * Double(sampleRate)))
        guard window > 0, voice.frameCount >= frames + maximumLag else { return nil }

        // Loudest voice window, searched in half-window steps.
        let voiceSamples = voice.samples
        var bestStart = 0
        var bestEnergy: Float = 0
        let step = max(window / 2, 1)
        for start in Swift.stride(from: 0, through: frames - window, by: step) {
            var energy: Float = 0
            vDSP_svesq(voiceSamples.baseAddress! + start, 1, &energy, vDSP_Length(window))
            if energy > bestEnergy {
                bestEnergy = energy
                bestStart = start
            }
        }
        guard bestEnergy > 1e-6 else { return nil }

        var mixWindow = [Float](repeating: 0, count: window)
        mixWindow.withUnsafeMutableBufferPointer { mix.read(channel: channel, from: bestStart, count: window, into: $0.baseAddress!) }
        var correlation = [Float](repeating: 0, count: maximumLag + 1)
        // correlation[lag] = Σ voice[start + lag + p] · mix[start + p]
        vDSP_conv(voiceSamples.baseAddress! + bestStart, 1, mixWindow, 1, &correlation, 1, vDSP_Length(maximumLag + 1), vDSP_Length(window))

        var peak: Float = 0
        var peakIndex: vDSP_Length = 0
        vDSP_maxvi(correlation, 1, &peak, &peakIndex, vDSP_Length(correlation.count))
        var mixEnergy: Float = 0
        vDSP_svesq(mixWindow, 1, &mixEnergy, vDSP_Length(window))
        let normalized = peak / max((mixEnergy * bestEnergy).squareRoot(), 1e-12)
        return normalized > 0.05 ? Int(peakIndex) : nil
    }
}

/// Renders mono audio through `AUSoundIsolation` offline: an `AVAudioEngine`
/// in manual rendering mode, fed by a source node, with the audio unit
/// between the source and the main mixer. (Calling the unit's render block
/// directly fails with kAudioUnitErr_NoConnection: its v2 bridge only pulls
/// input through a real connection.)
final class VoiceIsolator {
    private let engine = AVAudioEngine()
    private let effect: AVAudioUnitEffect
    private let feed: InputFeed
    private let blockSize: Int
    /// The audio unit's reported processing delay (set once the engine runs).
    private(set) var latencyFrames = 0

    init(sampleRate: Double, blockSize: Int) throws {
        guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1) else {
            throw SpeechRemovalError.audioUnitFailed("unsupported format")
        }
        self.blockSize = blockSize
        effect = AVAudioUnitEffect(audioComponentDescription: VoiceIsolationEngine.componentDescription)
        let feed = InputFeed()
        self.feed = feed
        // Output only the isolated voice.
        effect.auAudioUnit.parameterTree?.parameter(withAddress: AUParameterAddress(kAUSoundIsolationParam_WetDryMixPercent))?.value = 100

        let source = AVAudioSourceNode(format: format) { _, _, frameCount, audioBufferList in
            let buffers = UnsafeMutableAudioBufferListPointer(audioBufferList)
            if let data = buffers[0].mData?.assumingMemoryBound(to: Float.self) {
                feed.fill(data, count: Int(frameCount))
            }
            return noErr
        }
        do {
            try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: AVAudioFrameCount(blockSize))
            engine.attach(source)
            engine.attach(effect)
            engine.connect(source, to: effect, format: format)
            engine.connect(effect, to: engine.mainMixerNode, format: format)
            try engine.start()
        } catch {
            throw SpeechRemovalError.audioUnitFailed(error.localizedDescription)
        }
        latencyFrames = max(0, Int((effect.auAudioUnit.latency * sampleRate).rounded()))
    }

    deinit {
        engine.stop()
    }

    /// Renders `channel` of `input`, followed by silence, into `voice` (mono,
    /// longer than `input` so the delayed tail is captured).
    func render(channel: Int, of input: MappedPCMFile, into voice: MappedPCMFile, progress: (Double) -> Void) throws {
        guard let buffer = AVAudioPCMBuffer(pcmFormat: engine.manualRenderingFormat, frameCapacity: AVAudioFrameCount(blockSize)) else {
            throw SpeechRemovalError.audioUnitFailed("couldn't allocate buffers")
        }
        feed.start(input: input, channel: channel)
        defer { feed.stop() }

        let total = voice.frameCount
        var position = 0
        while position < total {
            if Task.isCancelled { throw CancellationError() }
            let count = min(blockSize, total - position)
            let status: AVAudioEngineManualRenderingStatus
            do {
                status = try engine.renderOffline(AVAudioFrameCount(count), to: buffer)
            } catch {
                throw SpeechRemovalError.audioUnitFailed(error.localizedDescription)
            }
            let rendered = Int(buffer.frameLength)
            guard status == .success, rendered > 0, let data = buffer.floatChannelData?[0] else {
                throw SpeechRemovalError.audioUnitFailed("render status \(status.rawValue)")
            }
            voice.write(channel: 0, at: position, count: rendered, from: data)
            position += rendered
            progress(Double(position) / Double(total))
        }
    }
}

/// Supplies one channel of a mapped file to the engine's source node, then
/// silence once the channel runs out. Only touched from the rendering thread
/// while a render is in progress.
private final class InputFeed: @unchecked Sendable {
    private var input: MappedPCMFile?
    private var channel = 0
    private var position = 0

    func start(input: MappedPCMFile, channel: Int) {
        self.input = input
        self.channel = channel
        position = 0
    }

    func stop() {
        input = nil
    }

    func fill(_ destination: UnsafeMutablePointer<Float>, count: Int) {
        if let input {
            input.read(channel: channel, from: position, count: count, into: destination)
        } else {
            destination.update(repeating: 0, count: count)
        }
        position += count
    }
}

/// Removes an estimated voice signal from a mix with a per-bin soft mask
/// `max(0, 1 − |V| / |M|)`, using a Hann-windowed STFT with 75% overlap
/// (whose squared windows sum to a constant 1.5).
struct SpectralMask {
    let fftSize: Int
    let hopSize: Int

    init(fftSize: Int, hopSize: Int) {
        precondition(hopSize * 4 == fftSize, "the window normalization assumes 75% overlap")
        self.fftSize = fftSize
        self.hopSize = hopSize
    }

    /// Writes `mix[channel]` with `voice[n + lag]` masked out into
    /// `output[channel]` (which must start zero-filled).
    func apply(mix: MappedPCMFile, channel: Int, voice: MappedPCMFile, lag: Int, output: MappedPCMFile) {
        let size = fftSize
        let window = (0..<size).map { Float(0.5 - 0.5 * cos(2 * Double.pi * Double($0) / Double(size))) }
        guard let forward = vDSP_DFT_zop_CreateSetup(nil, vDSP_Length(size), .FORWARD),
              let inverse = vDSP_DFT_zop_CreateSetup(forward, vDSP_Length(size), .INVERSE) else {
            preconditionFailure("vDSP does not support a DFT of size \(size)")
        }
        defer {
            vDSP_DFT_DestroySetup(inverse)
            vDSP_DFT_DestroySetup(forward)
        }

        let zeros = [Float](repeating: 0, count: size)
        var mixRaw = [Float](repeating: 0, count: size)
        var voiceRaw = [Float](repeating: 0, count: size)
        var mixFrame = [Float](repeating: 0, count: size)
        var voiceFrame = [Float](repeating: 0, count: size)
        var mixReal = [Float](repeating: 0, count: size)
        var mixImag = [Float](repeating: 0, count: size)
        var voiceReal = [Float](repeating: 0, count: size)
        var voiceImag = [Float](repeating: 0, count: size)
        var outReal = [Float](repeating: 0, count: size)
        var outImag = [Float](repeating: 0, count: size)
        // Undo the unscaled inverse DFT (1/N) and the window overlap (1/1.5).
        let scale = 1 / (Float(size) * 1.5)
        let destination = output.mutableSamples
        let channels = output.channels
        let frames = mix.frameCount

        for start in Swift.stride(from: -size, to: frames, by: hopSize) {
            mixRaw.withUnsafeMutableBufferPointer { mix.read(channel: channel, from: start, count: size, into: $0.baseAddress!) }
            voiceRaw.withUnsafeMutableBufferPointer { voice.read(channel: 0, from: start + lag, count: size, into: $0.baseAddress!) }
            vDSP.multiply(mixRaw, window, result: &mixFrame)
            vDSP.multiply(voiceRaw, window, result: &voiceFrame)
            vDSP_DFT_Execute(forward, mixFrame, zeros, &mixReal, &mixImag)
            vDSP_DFT_Execute(forward, voiceFrame, zeros, &voiceReal, &voiceImag)

            for bin in 0..<size {
                let mixMagnitude = (mixReal[bin] * mixReal[bin] + mixImag[bin] * mixImag[bin]).squareRoot()
                let voiceMagnitude = (voiceReal[bin] * voiceReal[bin] + voiceImag[bin] * voiceImag[bin]).squareRoot()
                let gain = max(0, 1 - voiceMagnitude / (mixMagnitude + 1e-9))
                mixReal[bin] *= gain
                mixImag[bin] *= gain
            }
            vDSP_DFT_Execute(inverse, mixReal, mixImag, &outReal, &outImag)

            for index in 0..<size {
                let frame = start + index
                guard frame >= 0, frame < frames else { continue }
                destination[frame * channels + channel] += outReal[index] * window[index] * scale
            }
        }
    }
}
