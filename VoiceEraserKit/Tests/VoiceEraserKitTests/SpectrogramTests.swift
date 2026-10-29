import Foundation
import Testing
@testable import VoiceEraserKit

/// Compares the Swift STFT code with PyTorch / demucs reference values
/// (Fixtures/dsp-fixtures.json, written by Scripts/make-dsp-fixtures.py).
struct SpectrogramTests {
    struct Case: Decodable {
        var fftSize: Int
        var hopSize: Int
        var signal: [Double]
        var bins: Int
        var frames: Int
        var real: [Double]
        var imag: [Double]
        var inverseInputReal: [Double]
        var inverseInputImag: [Double]
        var inverseLength: Int
        var inverse: [Double]

        var floatSignal: [Float] { signal.map(Float.init) }
        var inverseInput: ComplexSpectrogram {
            ComplexSpectrogram(bins: bins, frames: frames, real: inverseInputReal.map(Float.init), imag: inverseInputImag.map(Float.init))
        }
    }

    struct Fixtures: Decodable {
        var stft: Case
        var demucs: Case
    }

    static func fixtures() throws -> Fixtures {
        let url = try #require(Bundle.module.url(forResource: "dsp-fixtures", withExtension: "json", subdirectory: "Fixtures"))
        return try JSONDecoder().decode(Fixtures.self, from: Data(contentsOf: url))
    }

    static func maxError(_ actual: [Float], _ expected: [Double]) -> Double {
        zip(actual, expected).map { abs(Double($0) - $1) }.max() ?? .infinity
    }

    @Test func stftMatchesTorch() throws {
        let fixture = try Self.fixtures().stft
        let stft = ShortTimeFourierTransform(fftSize: fixture.fftSize, hopSize: fixture.hopSize)
        let spectrogram = stft.forward(fixture.floatSignal)
        #expect(spectrogram.bins == fixture.bins)
        #expect(spectrogram.frames == fixture.frames)
        #expect(Self.maxError(spectrogram.real, fixture.real) < 1e-4)
        #expect(Self.maxError(spectrogram.imag, fixture.imag) < 1e-4)
    }

    @Test func istftMatchesTorch() throws {
        let fixture = try Self.fixtures().stft
        let stft = ShortTimeFourierTransform(fftSize: fixture.fftSize, hopSize: fixture.hopSize)
        let signal = stft.inverse(fixture.inverseInput, length: fixture.inverseLength)
        #expect(signal.count == fixture.inverseLength)
        #expect(Self.maxError(signal, fixture.inverse) < 1e-4)
    }

    @Test func demucsSpectrogramMatchesReference() throws {
        let fixture = try Self.fixtures().demucs
        let spectrogram = DemucsSpectrogram(fftSize: fixture.fftSize, hopSize: fixture.hopSize)
        let result = spectrogram.forward(fixture.floatSignal)
        #expect(result.bins == fixture.bins)
        #expect(result.frames == fixture.frames)
        #expect(Self.maxError(result.real, fixture.real) < 1e-4)
        #expect(Self.maxError(result.imag, fixture.imag) < 1e-4)
    }

    @Test func demucsInverseMatchesReference() throws {
        let fixture = try Self.fixtures().demucs
        let spectrogram = DemucsSpectrogram(fftSize: fixture.fftSize, hopSize: fixture.hopSize)
        let signal = spectrogram.inverse(fixture.inverseInput, length: fixture.inverseLength)
        #expect(signal.count == fixture.inverseLength)
        #expect(Self.maxError(signal, fixture.inverse) < 1e-4)
    }

    /// At the model's real size the spectrogram has the shape the Core ML
    /// model expects and inverts back to the input.
    @Test func demucsModelSizeRoundTrip() {
        let length = DemucsEngine.segmentLength
        var generator = SplitMix64(seed: 7)
        let signal = (0..<length).map { _ in Float.random(in: -0.5...0.5, using: &generator) }
        let spectrogram = DemucsSpectrogram()
        let forward = spectrogram.forward(signal)
        #expect(forward.bins == 2048)
        #expect(forward.frames == 336)
        let restored = spectrogram.inverse(forward, length: length)
        let error = zip(restored, signal).map { abs($0 - $1) }.max() ?? .infinity
        #expect(error < 1e-3)
    }

    @Test func reflectPadMirrorsWithoutRepeatingEdges() {
        let padded = ShortTimeFourierTransform.reflectPad([1, 2, 3, 4], left: 2, right: 3)
        #expect(padded == [3, 2, 1, 2, 3, 4, 3, 2, 1])
    }

    @Test func shortInputIsZeroPaddedBeforeReflecting() {
        // demucs pad1d: length 2 <= max pad 3, so one zero goes on the right first.
        let padded = DemucsSpectrogram.reflectPadAllowingShortInput([1, 2], left: 1, right: 3)
        #expect(padded.count == 6)
        #expect(Array(padded[1..<3]) == [1, 2])
    }
}

/// Small deterministic RNG for reproducible test signals.
struct SplitMix64: RandomNumberGenerator {
    var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var value = state
        value = (value ^ (value >> 30)) &* 0xBF58_476D_1CE4_E5B9
        value = (value ^ (value >> 27)) &* 0x94D0_49BB_1331_11EB
        return value ^ (value >> 31)
    }
}
