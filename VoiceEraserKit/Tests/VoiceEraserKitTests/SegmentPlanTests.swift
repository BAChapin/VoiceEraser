import Testing
@testable import VoiceEraserKit

struct SegmentPlanTests {
    @Test func segmentsCoverTheSignalWithQuarterOverlap() {
        let plan = SegmentPlan(totalLength: 1_000_000, segmentLength: 343_980)
        #expect(plan.stride == 257_985)
        #expect(plan.segments.map(\.offset) == [0, 257_985, 515_970, 773_955])
        #expect(plan.segments.map(\.length) == [343_980, 343_980, 343_980, 226_045])
        // Full segments need no padding.
        #expect(plan.segments[0].inputStart == 0)
        #expect(plan.segments[0].trimStart == 0)
        // The last one borrows half its missing length from earlier audio.
        let last = plan.segments[3]
        let delta = 343_980 - 226_045
        #expect(last.inputStart == 773_955 - delta / 2)
        #expect(last.trimStart == delta / 2)
    }

    @Test func shortSignalIsOneCenteredSegment() {
        let plan = SegmentPlan(totalLength: 1000, segmentLength: 4000)
        #expect(plan.segments.count == 1)
        #expect(plan.segments[0].length == 1000)
        #expect(plan.segments[0].inputStart == -1500)
        #expect(plan.segments[0].trimStart == 1500)
    }

    @Test func emptySignalHasNoSegments() {
        #expect(SegmentPlan(totalLength: 0, segmentLength: 100).segments.isEmpty)
    }

    @Test func weightsAreATriangleNormalizedToOne() {
        let weights = SegmentPlan.weights(segmentLength: 6)
        // arange(1, 4) ++ arange(3, 0, -1) = [1, 2, 3, 3, 2, 1], over 3.
        #expect(weights == [1, 2, 3, 3, 2, 1].map { Float($0) / 3 })
        let odd = SegmentPlan.weights(segmentLength: 5)
        #expect(odd == [1, 2, 3, 2, 1].map { Float($0) / 3 })
    }

    @Test func overlapAddReturnsWeightedAverage() {
        var accumulator = OverlapAddAccumulator(channels: 1)
        let weights: [Float] = [1, 1, 1, 1]
        accumulator.add(at: 0, count: 4, channels: [[2, 2, 2, 2]], sourceStart: 0, weights: weights)
        accumulator.add(at: 2, count: 4, channels: [[9, 4, 4, 4, 4]], sourceStart: 1, weights: weights)
        let first = accumulator.drain(upTo: 2)
        #expect(first.start == 0)
        #expect(first.channels[0] == [2, 2])
        let rest = accumulator.drain(upTo: 6)
        #expect(rest.start == 2)
        #expect(rest.channels[0] == [3, 3, 4, 4])
        #expect(accumulator.base == 6)
    }
}
