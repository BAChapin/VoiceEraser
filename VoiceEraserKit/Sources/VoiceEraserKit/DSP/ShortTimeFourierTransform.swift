import Accelerate

/// A one-sided complex spectrogram stored bin-major: element `(bin, frame)` is
/// at `bin * frames + frame`, matching PyTorch's `[freqs, frames]` layout.
public struct ComplexSpectrogram: Sendable, Equatable {
    public let bins: Int
    public let frames: Int
    public var real: [Float]
    public var imag: [Float]

    public init(bins: Int, frames: Int) {
        self.bins = bins
        self.frames = frames
        real = [Float](repeating: 0, count: bins * frames)
        imag = [Float](repeating: 0, count: bins * frames)
    }

    public init(bins: Int, frames: Int, real: [Float], imag: [Float]) {
        precondition(real.count == bins * frames && imag.count == bins * frames, "spectrogram size mismatch")
        self.bins = bins
        self.frames = frames
        self.real = real
        self.imag = imag
    }
}

/// Short-time Fourier transform that matches PyTorch's
/// `torch.stft(..., window=torch.hann_window(n), normalized=True, center=True,
/// pad_mode="reflect", return_complex=True)` and the corresponding
/// `torch.istft(..., normalized=True, center=True, length=...)`.
public final class ShortTimeFourierTransform: @unchecked Sendable {
    public let fftSize: Int
    public let hopSize: Int
    /// Periodic Hann window (`torch.hann_window` default).
    let window: [Float]
    private let forwardSetup: OpaquePointer
    private let inverseSetup: OpaquePointer

    /// - Parameters:
    ///   - fftSize: a size vDSP's DFT supports (a power of two ≥ 16 works).
    ///   - hopSize: frame advance in samples.
    public init(fftSize: Int, hopSize: Int) {
        precondition(fftSize >= 16 && fftSize.isMultiple(of: 2) && hopSize > 0, "unsupported STFT size")
        self.fftSize = fftSize
        self.hopSize = hopSize
        window = (0..<fftSize).map { n in
            Float(0.5 - 0.5 * cos(2 * Double.pi * Double(n) / Double(fftSize)))
        }
        guard let forward = vDSP_DFT_zop_CreateSetup(nil, vDSP_Length(fftSize), .FORWARD),
              let inverse = vDSP_DFT_zop_CreateSetup(forward, vDSP_Length(fftSize), .INVERSE) else {
            preconditionFailure("vDSP does not support a DFT of size \(fftSize)")
        }
        forwardSetup = forward
        inverseSetup = inverse
    }

    deinit {
        vDSP_DFT_DestroySetup(inverseSetup)
        vDSP_DFT_DestroySetup(forwardSetup)
    }

    public var bins: Int { fftSize / 2 + 1 }

    /// Number of frames `forward` produces for a signal of `length` samples.
    public func frameCount(forLength length: Int) -> Int {
        1 + length / hopSize
    }

    /// `torch.stft` of `signal` (length must exceed `fftSize / 2` for the
    /// reflect padding).
    public func forward(_ signal: [Float]) -> ComplexSpectrogram {
        let half = fftSize / 2
        let padded = Self.reflectPad(signal, left: half, right: half)
        let frames = frameCount(forLength: signal.count)
        var output = ComplexSpectrogram(bins: bins, frames: frames)
        let scale = 1 / Float(fftSize).squareRoot()

        var inReal = [Float](repeating: 0, count: fftSize)
        let inImag = [Float](repeating: 0, count: fftSize)
        var outReal = [Float](repeating: 0, count: fftSize)
        var outImag = [Float](repeating: 0, count: fftSize)
        padded.withUnsafeBufferPointer { padded in
            for frame in 0..<frames {
                let start = frame * hopSize
                vDSP_vmul(padded.baseAddress! + start, 1, window, 1, &inReal, 1, vDSP_Length(fftSize))
                vDSP_DFT_Execute(forwardSetup, inReal, inImag, &outReal, &outImag)
                for bin in 0..<bins {
                    output.real[bin * frames + frame] = outReal[bin] * scale
                    output.imag[bin * frames + frame] = outImag[bin] * scale
                }
            }
        }
        return output
    }

    /// `torch.istft` of `spectrogram`, trimmed or zero-padded to `length`.
    public func inverse(_ spectrogram: ComplexSpectrogram, length: Int) -> [Float] {
        precondition(spectrogram.bins == bins, "spectrogram has \(spectrogram.bins) bins, expected \(bins)")
        let half = fftSize / 2
        let frames = spectrogram.frames
        guard frames > 0 else { return [Float](repeating: 0, count: length) }
        let fullLength = fftSize + hopSize * (frames - 1)
        var overlapAdd = [Float](repeating: 0, count: fullLength)
        var envelope = [Float](repeating: 0, count: fullLength)
        let squaredWindow = vDSP.square(window)
        let scale = 1 / Float(fftSize).squareRoot()

        var inReal = [Float](repeating: 0, count: fftSize)
        var inImag = [Float](repeating: 0, count: fftSize)
        var outReal = [Float](repeating: 0, count: fftSize)
        var outImag = [Float](repeating: 0, count: fftSize)
        var frameSignal = [Float](repeating: 0, count: fftSize)
        for frame in 0..<frames {
            for bin in 0..<bins {
                inReal[bin] = spectrogram.real[bin * frames + frame]
                inImag[bin] = spectrogram.imag[bin * frames + frame]
            }
            // A real inverse FFT ignores the imaginary parts at DC and Nyquist.
            inImag[0] = 0
            inImag[half] = 0
            for bin in 1..<half {
                inReal[fftSize - bin] = inReal[bin]
                inImag[fftSize - bin] = -inImag[bin]
            }
            vDSP_DFT_Execute(inverseSetup, inReal, inImag, &outReal, &outImag)
            vDSP_vmul(outReal, 1, window, 1, &frameSignal, 1, vDSP_Length(fftSize))
            let start = frame * hopSize
            overlapAdd.withUnsafeMutableBufferPointer { buffer in
                let target = buffer.baseAddress! + start
                var factor = scale
                vDSP_vsma(frameSignal, 1, &factor, target, 1, target, 1, vDSP_Length(fftSize))
            }
            envelope.withUnsafeMutableBufferPointer { buffer in
                let target = buffer.baseAddress! + start
                vDSP_vadd(target, 1, squaredWindow, 1, target, 1, vDSP_Length(fftSize))
            }
        }

        var result = [Float](repeating: 0, count: length)
        for index in 0..<length {
            let source = half + index
            guard source < fullLength else { break }
            let weight = envelope[source]
            result[index] = weight > 1e-11 ? overlapAdd[source] / weight : 0
        }
        return result
    }

    /// `torch.nn.functional.pad(x, (left, right), mode="reflect")`: mirrors
    /// around the edge samples without repeating them.
    static func reflectPad(_ signal: [Float], left: Int, right: Int) -> [Float] {
        let count = signal.count
        precondition(left < count && right < count, "reflect padding must be shorter than the signal")
        var padded = [Float](repeating: 0, count: count + left + right)
        for index in 0..<left {
            padded[index] = signal[left - index]
        }
        for index in 0..<count {
            padded[left + index] = signal[index]
        }
        for index in 0..<right {
            padded[left + count + index] = signal[count - 2 - index]
        }
        return padded
    }
}
