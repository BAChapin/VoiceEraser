import Foundation

/// The spectrogram HTDemucs feeds its frequency branch (`HTDemucs._spec`) and
/// its inverse (`HTDemucs._ispec`), from demucs/htdemucs.py.
///
/// `_spec` reflect-pads the signal by 3/4 of a hop on each side (plus up to a
/// hop on the right) so that the output has exactly `ceil(length / hop)`
/// frames, drops the Nyquist bin, and drops two frames at each end.
public final class DemucsSpectrogram: @unchecked Sendable {
    public let stft: ShortTimeFourierTransform

    /// HTDemucs uses `fftSize` 4096 and `hopSize` 1024; the hop must be a
    /// quarter of the FFT size.
    public init(fftSize: Int = 4096, hopSize: Int = 1024) {
        precondition(hopSize * 4 == fftSize, "HTDemucs requires hop = fftSize / 4")
        stft = ShortTimeFourierTransform(fftSize: fftSize, hopSize: hopSize)
    }

    public var bins: Int { stft.fftSize / 2 }

    public func frameCount(forLength length: Int) -> Int {
        (length + stft.hopSize - 1) / stft.hopSize
    }

    /// `HTDemucs._spec` for one channel: `bins` × `frameCount(forLength:)`.
    public func forward(_ signal: [Float]) -> ComplexSpectrogram {
        let hop = stft.hopSize
        let frames = frameCount(forLength: signal.count)
        let pad = hop / 2 * 3
        let padded = Self.reflectPadAllowingShortInput(signal, left: pad, right: pad + frames * hop - signal.count)
        let full = stft.forward(padded)
        precondition(full.frames == frames + 4, "unexpected frame count \(full.frames)")

        var output = ComplexSpectrogram(bins: bins, frames: frames)
        for bin in 0..<bins {
            let source = bin * full.frames + 2
            let target = bin * frames
            output.real.replaceSubrange(target..<(target + frames), with: full.real[source..<(source + frames)])
            output.imag.replaceSubrange(target..<(target + frames), with: full.imag[source..<(source + frames)])
        }
        return output
    }

    /// `HTDemucs._ispec` for one channel: a `bins` × `ceil(length / hop)`
    /// spectrogram back to `length` samples.
    public func inverse(_ spectrogram: ComplexSpectrogram, length: Int) -> [Float] {
        precondition(spectrogram.bins == bins, "spectrogram has \(spectrogram.bins) bins, expected \(bins)")
        let hop = stft.hopSize
        let frames = spectrogram.frames
        // Add the Nyquist bin back and two empty frames on each side.
        var full = ComplexSpectrogram(bins: bins + 1, frames: frames + 4)
        for bin in 0..<bins {
            let source = bin * frames
            let target = bin * full.frames + 2
            full.real.replaceSubrange(target..<(target + frames), with: spectrogram.real[source..<(source + frames)])
            full.imag.replaceSubrange(target..<(target + frames), with: spectrogram.imag[source..<(source + frames)])
        }
        let pad = hop / 2 * 3
        let paddedLength = hop * ((length + hop - 1) / hop) + 2 * pad
        let signal = stft.inverse(full, length: paddedLength)
        return Array(signal[pad..<(pad + length)])
    }

    /// `demucs.hdemucs.pad1d(..., mode="reflect")`: reflect padding that first
    /// zero-pads inputs too short to reflect.
    static func reflectPadAllowingShortInput(_ signal: [Float], left: Int, right: Int) -> [Float] {
        let maxPad = max(left, right)
        guard signal.count <= maxPad else {
            return ShortTimeFourierTransform.reflectPad(signal, left: left, right: right)
        }
        let extra = maxPad - signal.count + 1
        let extraRight = min(right, extra)
        let extraLeft = extra - extraRight
        let widened = [Float](repeating: 0, count: extraLeft) + signal + [Float](repeating: 0, count: extraRight)
        return ShortTimeFourierTransform.reflectPad(widened, left: left - extraLeft, right: right - extraRight)
    }
}
