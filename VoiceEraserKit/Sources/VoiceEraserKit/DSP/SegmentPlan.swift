import Foundation

/// How `demucs.apply.apply_model` splits a long signal into model-sized
/// segments and blends them back together.
///
/// Segments start every `stride = (1 - overlap) * segmentLength` samples.
/// Each is cut with context from its neighbours (or zeros past the ends) to
/// exactly `segmentLength`, separated, trimmed back to its own span, and
/// overlap-added with a triangular weight.
public struct SegmentPlan: Sendable, Equatable {
    public struct Segment: Sendable, Equatable {
        /// First output frame this segment covers.
        public var offset: Int
        /// Frames of output this segment contributes (≤ `segmentLength`).
        public var length: Int
        /// First input frame of the padded model input; may be negative.
        public var inputStart: Int
        /// Index into the model output where this segment's span begins.
        public var trimStart: Int
    }

    public let totalLength: Int
    public let segmentLength: Int
    public let stride: Int
    public let segments: [Segment]

    public init(totalLength: Int, segmentLength: Int, overlap: Double = 0.25) {
        precondition(segmentLength > 0 && overlap >= 0 && overlap < 1, "invalid segment plan")
        self.totalLength = totalLength
        self.segmentLength = segmentLength
        stride = Int((1 - overlap) * Double(segmentLength))
        segments = Swift.stride(from: 0, to: totalLength, by: stride).map { [segmentLength] offset in
            let length = min(segmentLength, totalLength - offset)
            let delta = segmentLength - length
            return Segment(offset: offset, length: length, inputStart: offset - delta / 2, trimStart: delta / 2)
        }
    }

    /// The crossfade weight for position `index` within a segment:
    /// `cat(arange(1, L//2 + 1), arange(L - L//2, 0, -1)) / max`.
    public static func weights(segmentLength: Int) -> [Float] {
        let half = segmentLength / 2
        var weights = [Float](repeating: 0, count: segmentLength)
        for index in 0..<half {
            weights[index] = Float(index + 1)
        }
        for index in half..<segmentLength {
            weights[index] = Float(segmentLength - index)
        }
        let peak = weights.max() ?? 1
        return weights.map { $0 / peak }
    }
}
