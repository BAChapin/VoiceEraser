import Foundation

/// Drops progress updates that are too small to show, so UI updates stay
/// cheap when an engine reports thousands of times per second.
public final class ProgressThrottle: @unchecked Sendable {
    private let lock = NSLock()
    private let minimumStep: Double
    private var last: PipelineProgress?

    public init(minimumStep: Double = 0.002) {
        self.minimumStep = minimumStep
    }

    /// True if `progress` should be shown: the first update, a new stage or
    /// track, completion, or a large enough step.
    public func shouldReport(_ progress: PipelineProgress) -> Bool {
        lock.withLock {
            if let last,
               last.stage == progress.stage,
               last.track == progress.track,
               progress.fraction < 1,
               abs(progress.fraction - last.fraction) < minimumStep {
                return false
            }
            last = progress
            return true
        }
    }
}
