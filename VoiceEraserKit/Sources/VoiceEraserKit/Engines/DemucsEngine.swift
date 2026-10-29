import CoreML
import Foundation

/// High-quality speech removal with the Hybrid Transformer Demucs vocals
/// model (Scripts/convert-model.py documents the Core ML contract).
///
/// Mirrors `demucs.separate` + `demucs.apply.apply_model(shifts=0,
/// overlap=0.25)` for the vocals source, then subtracts the vocals from the
/// original mix so everything else is left exactly as it was.
public final class DemucsEngine: SpeechRemovalEngine, @unchecked Sendable {
    /// Model input length: 7.8 s at 44.1 kHz.
    public static let segmentLength = 343_980
    public static let modelSampleRate = 44_100
    public static let modelResourceName = "HTDemucsVocals"

    public var sampleRate: Int { Self.modelSampleRate }

    private let model: MLModel
    private let spectrogram = DemucsSpectrogram()
    private let weights = SegmentPlan.weights(segmentLength: DemucsEngine.segmentLength)

    init(model: MLModel) {
        self.model = model
    }

    /// The compiled model in an app bundle, if this build includes it.
    public static func bundledModelURL(in bundle: Bundle = .main) -> URL? {
        bundle.url(forResource: modelResourceName, withExtension: "mlmodelc")
    }

    /// Loads a compiled `.mlmodelc`, or compiles and loads an `.mlpackage`.
    public static func load(from url: URL, computeUnits: MLComputeUnits = .all) async throws -> DemucsEngine {
        let configuration = MLModelConfiguration()
        configuration.computeUnits = computeUnits
        var compiledURL = url
        if url.pathExtension == "mlpackage" {
            compiledURL = try await MLModel.compileModel(at: url)
        }
        let model = try await MLModel.load(contentsOf: compiledURL, configuration: configuration)
        return DemucsEngine(model: model)
    }

    public func removeSpeech(
        input: MappedPCMFile,
        output: MappedPCMFile,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws {
        let frames = input.frameCount
        guard frames > 0 else { return }
        let plan = SegmentPlan(totalLength: frames, segmentLength: Self.segmentLength)
        let pairs = input.stereoChannelPairs
        let totalSteps = Double(pairs.count * plan.segments.count)
        var completedSteps = 0.0

        for pair in pairs {
            let (mean, std) = Self.monoStatistics(of: input, left: pair.left, right: pair.right)
            guard std > 1e-8 else {
                // Digital silence: nothing to remove.
                Self.copy(input, to: output, channels: [pair.left, pair.right])
                completedSteps += Double(plan.segments.count)
                progress(completedSteps / totalSteps)
                continue
            }

            var accumulator = OverlapAddAccumulator(channels: 2)
            for (segmentIndex, segment) in plan.segments.enumerated() {
                try Task.checkCancellation()
                let mix = readNormalizedSegment(input, pair: pair, segment: segment, mean: mean, std: std)
                let vocals = try await separateVocals(left: mix.left, right: mix.right)
                accumulator.add(
                    at: segment.offset,
                    count: segment.length,
                    channels: [vocals.left, vocals.right],
                    sourceStart: segment.trimStart,
                    weights: weights
                )

                let finalizedUpTo = segmentIndex + 1 < plan.segments.count ? plan.segments[segmentIndex + 1].offset : frames
                let finished = accumulator.drain(upTo: finalizedUpTo)
                writeResidual(input: input, output: output, pair: pair, vocals: finished, scale: std)

                completedSteps += 1
                progress(completedSteps / totalSteps)
            }
        }
        output.synchronize()
    }

    // MARK: - Segments

    private func readNormalizedSegment(
        _ input: MappedPCMFile,
        pair: (left: Int, right: Int),
        segment: SegmentPlan.Segment,
        mean: Float,
        std: Float
    ) -> (left: [Float], right: [Float]) {
        let length = Self.segmentLength
        var left = [Float](repeating: 0, count: length)
        var right = [Float](repeating: 0, count: length)
        left.withUnsafeMutableBufferPointer { input.read(channel: pair.left, from: segment.inputStart, count: length, into: $0.baseAddress!) }
        right.withUnsafeMutableBufferPointer { input.read(channel: pair.right, from: segment.inputStart, count: length, into: $0.baseAddress!) }
        // Normalize real samples only; padding past the ends stays zero, as in
        // demucs (which normalizes the whole track before padding segments).
        let valid = max(0, -segment.inputStart)..<min(length, input.frameCount - segment.inputStart)
        for index in valid {
            left[index] = (left[index] - mean) / std
            right[index] = (right[index] - mean) / std
        }
        return (left, right)
    }

    /// Runs the model on one normalized stereo segment and returns the vocals
    /// waveform (`iSTFT(vocals_spec) + vocals_wave`).
    func separateVocals(left: [Float], right: [Float]) async throws -> (left: [Float], right: [Float]) {
        let length = Self.segmentLength
        let specLeft = spectrogram.forward(left)
        let specRight = spectrogram.forward(right)
        let bins = specLeft.bins
        let frames = specLeft.frames

        let mixArray = try MLMultiArray(shape: [1, 2, NSNumber(value: length)], dataType: .float32)
        mixArray.withUnsafeMutableBufferPointer(ofType: Float.self) { buffer, strides in
            let channelStride = strides[1]
            for index in 0..<length {
                buffer[index * strides[2]] = left[index]
                buffer[channelStride + index * strides[2]] = right[index]
            }
        }
        let specArray = try MLMultiArray(shape: [1, 4, NSNumber(value: bins), NSNumber(value: frames)], dataType: .float32)
        specArray.withUnsafeMutableBufferPointer(ofType: Float.self) { buffer, strides in
            let planes = [specLeft.real, specLeft.imag, specRight.real, specRight.imag]
            for (plane, values) in planes.enumerated() {
                for bin in 0..<bins {
                    for frame in 0..<frames {
                        buffer[plane * strides[1] + bin * strides[2] + frame * strides[3]] = values[bin * frames + frame]
                    }
                }
            }
        }

        let inputs = try MLDictionaryFeatureProvider(dictionary: ["mix": mixArray, "spec": specArray])
        let outputs = try await model.prediction(from: inputs)
        guard let vocalsSpec = outputs.featureValue(for: "vocals_spec")?.multiArrayValue else {
            throw SpeechRemovalError.modelOutputMissing("vocals_spec")
        }
        guard let vocalsWave = outputs.featureValue(for: "vocals_wave")?.multiArrayValue else {
            throw SpeechRemovalError.modelOutputMissing("vocals_wave")
        }

        let specValues = Self.floats(vocalsSpec, shape: [4, bins, frames])
        let waveValues = Self.floats(vocalsWave, shape: [2, length])
        let plane = bins * frames
        var results: [[Float]] = []
        for channel in 0..<2 {
            let real = Array(specValues[(2 * channel * plane)..<((2 * channel + 1) * plane)])
            let imag = Array(specValues[((2 * channel + 1) * plane)..<((2 * channel + 2) * plane)])
            var signal = spectrogram.inverse(ComplexSpectrogram(bins: bins, frames: frames, real: real, imag: imag), length: length)
            for index in 0..<length {
                signal[index] += waveValues[channel * length + index]
            }
            results.append(signal)
        }
        return (results[0], results[1])
    }

    /// Copies a `[1, a, b]` or `[1, a, b, c]` multi-array into a contiguous
    /// row-major `Float` array, honouring Core ML's (possibly padded) strides.
    static func floats(_ array: MLMultiArray, shape: [Int]) -> [Float] {
        precondition(shape.count == 2 || shape.count == 3, "only rank 3 and 4 outputs are supported")
        let strides = Array(array.strides.map(\.intValue).dropFirst())
        let dims = shape.count == 2 ? [1] + shape : shape
        let steps = shape.count == 2 ? [0] + strides : strides
        var result = [Float](repeating: 0, count: dims[0] * dims[1] * dims[2])

        func copy(_ read: (Int) -> Float) {
            var flat = 0
            for outer in 0..<dims[0] {
                for middle in 0..<dims[1] {
                    let rowOffset = outer * steps[0] + middle * steps[1]
                    for inner in 0..<dims[2] {
                        result[flat] = read(rowOffset + inner * steps[2])
                        flat += 1
                    }
                }
            }
        }

        switch array.dataType {
        #if arch(arm64)
        case .float16:
            array.withUnsafeBufferPointer(ofType: Float16.self) { buffer in copy { Float(buffer[$0]) } }
        #endif
        case .double:
            array.withUnsafeBufferPointer(ofType: Double.self) { buffer in copy { Float(buffer[$0]) } }
        default:
            array.withUnsafeBufferPointer(ofType: Float.self) { buffer in copy { buffer[$0] } }
        }
        return result
    }

    // MARK: - Mixing

    private func writeResidual(
        input: MappedPCMFile,
        output: MappedPCMFile,
        pair: (left: Int, right: Int),
        vocals: OverlapAddAccumulator.Drained,
        scale: Float
    ) {
        let source = input.samples
        let destination = output.mutableSamples
        let channels = input.channels
        for offset in 0..<vocals.count {
            let frame = vocals.start + offset
            let left = vocals.channels[0][offset] * scale
            let right = vocals.channels[1][offset] * scale
            if pair.left == pair.right {
                let sample = frame * channels + pair.left
                destination[sample] = source[sample] - (left + right) / 2
            } else {
                destination[frame * channels + pair.left] = source[frame * channels + pair.left] - left
                destination[frame * channels + pair.right] = source[frame * channels + pair.right] - right
            }
        }
    }

    /// Mean and (unbiased) standard deviation of the mono downmix, as
    /// `demucs.separate` normalizes a track before separation.
    static func monoStatistics(of input: MappedPCMFile, left: Int, right: Int) -> (mean: Float, std: Float) {
        let samples = input.samples
        let channels = input.channels
        let frames = input.frameCount
        var sum = 0.0
        for frame in 0..<frames {
            sum += (Double(samples[frame * channels + left]) + Double(samples[frame * channels + right])) / 2
        }
        let mean = sum / Double(frames)
        var squares = 0.0
        for frame in 0..<frames {
            let value = (Double(samples[frame * channels + left]) + Double(samples[frame * channels + right])) / 2 - mean
            squares += value * value
        }
        let variance = frames > 1 ? squares / Double(frames - 1) : 0
        return (Float(mean), Float(variance.squareRoot()))
    }

    static func copy(_ input: MappedPCMFile, to output: MappedPCMFile, channels selected: [Int]) {
        let source = input.samples
        let destination = output.mutableSamples
        for frame in 0..<input.frameCount {
            for channel in Set(selected) {
                destination[frame * input.channels + channel] = source[frame * input.channels + channel]
            }
        }
    }
}

/// Sliding overlap-add buffer for weighted segment outputs. Frames are
/// drained (divided by their summed weight) once no later segment can add to
/// them.
struct OverlapAddAccumulator {
    struct Drained {
        var start: Int
        var count: Int
        var channels: [[Float]]
    }

    private(set) var base = 0
    private var sums: [[Float]]
    private var weightSums: [Float] = []

    init(channels: Int) {
        sums = Array(repeating: [], count: channels)
    }

    /// Adds `weights[i] * channels[c][sourceStart + i]` at frame `offset + i`
    /// for `i` in `0..<count`.
    mutating func add(at offset: Int, count: Int, channels values: [[Float]], sourceStart: Int, weights: [Float]) {
        precondition(offset >= base, "segment starts before drained frames")
        let end = offset + count
        let needed = end - base
        if weightSums.count < needed {
            let extra = needed - weightSums.count
            weightSums += [Float](repeating: 0, count: extra)
            for channel in sums.indices {
                sums[channel] += [Float](repeating: 0, count: extra)
            }
        }
        for index in 0..<count {
            let target = offset - base + index
            weightSums[target] += weights[index]
            for channel in sums.indices {
                sums[channel][target] += weights[index] * values[channel][sourceStart + index]
            }
        }
    }

    /// Removes and returns the normalized frames before `frame`.
    mutating func drain(upTo frame: Int) -> Drained {
        let count = min(max(frame - base, 0), weightSums.count)
        var channels: [[Float]] = []
        for channel in sums.indices {
            var values = Array(sums[channel][0..<count])
            for index in 0..<count where weightSums[index] > 0 {
                values[index] /= weightSums[index]
            }
            channels.append(values)
            sums[channel].removeFirst(count)
        }
        weightSums.removeFirst(count)
        let drained = Drained(start: base, count: count, channels: channels)
        base += count
        return drained
    }
}
