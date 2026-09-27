import Foundation
import Testing

@testable import NeuralSheetCore

/// Runs `body` with a stereo take of `frames` frames whose channels are `left` and `right`.
private func withTake<T>(
    left: [Float], right: [Float]? = nil, loop: LoopWindow? = nil,
    _ body: (TimeStretcher.Input) -> T
) -> T {
    let rightChannel = right ?? left

    return left.withUnsafeBufferPointer { l in
        rightChannel.withUnsafeBufferPointer { r in
            body(TimeStretcher.Input(left: l.baseAddress!, right: r.baseAddress!, frameCount: left.count,
                                     isStereo: right != nil, loop: loop))
        }
    }
}

/// `frames` frames out of `stretcher`, in blocks of `block`.
private func render(_ stretcher: TimeStretcher, frames: Int, block: Int, input: TimeStretcher.Input) -> (left: [Float], right: [Float]) {
    var left = [Float](repeating: 0, count: frames)
    var right = [Float](repeating: 0, count: frames)

    left.withUnsafeMutableBufferPointer { l in
        right.withUnsafeMutableBufferPointer { r in
            var done = 0
            while done < frames {
                let n = min(block, frames - done)
                stretcher.render(left: l.baseAddress! + done, right: r.baseAddress! + done, frames: n, input: input)
                done += n
            }
        }
    }

    return (left, right)
}

private func sine(hz: Double, seconds: Double, rate: Double) -> [Float] {
    let count = Int(seconds * rate)
    let step: Double = 2 * Double.pi * hz / rate

    return (0..<count).map { index -> Float in
        let angle: Double = step * Double(index)
        return Float(Foundation.sin(angle))
    }
}

/// Zero crossings per second, which is twice the frequency of a sine.
private func crossingsPerSecond(_ samples: ArraySlice<Float>, rate: Double) -> Double {
    var crossings = 0
    var previous = samples.first ?? 0

    for sample in samples.dropFirst() {
        if (previous < 0 && sample >= 0) || (previous >= 0 && sample < 0) { crossings += 1 }
        previous = sample
    }

    return Double(crossings) / (Double(samples.count) / rate)
}

@Test func speedOneIsTheInputSampleForSample() {
    var generator = SystemRandomNumberGenerator()
    let left = (0..<48_000).map { _ in Float.random(in: -1...1, using: &generator) }
    let right = (0..<48_000).map { _ in Float.random(in: -1...1, using: &generator) }

    withTake(left: left, right: right) { input in
        let stretcher = TimeStretcher(sampleRate: 48_000, maxBlockFrames: 512)
        stretcher.speed = 1
        stretcher.reset(at: 1_000, input: input)

        let out = render(stretcher, frames: 20_000, block: 128, input: input)

        // Within a rounding step: the crossfade of a sample with itself is `x(1 - f) + xf`.
        let leftMatches = zip(out.left, left[1_000 ..< 21_000]).allSatisfy { abs($0 - $1) < 1e-6 }
        let rightMatches = zip(out.right, right[1_000 ..< 21_000]).allSatisfy { abs($0 - $1) < 1e-6 }
        #expect(leftMatches)
        #expect(rightMatches)
        #expect(abs(stretcher.position - 21_000) <= Double(stretcher.framesPerIteration),
                "the position runs at most one window ahead of what has been handed over")
    }
}

@Test func thePositionAdvancesAtTheSpeed() {
    let left = [Float](repeating: 0, count: 200_000)

    withTake(left: left) { input in
        for speed in [0.5, 0.75, 1.5] {
            let stretcher = TimeStretcher(sampleRate: 48_000, maxBlockFrames: 1024)
            stretcher.speed = speed
            stretcher.reset(at: 10_000, input: input)

            _ = render(stretcher, frames: 48_000, block: 256, input: input)

            // Whatever is buffered in the ring has been consumed from the take already.
            let expected = 10_000 + Double(48_000) * speed
            #expect(abs(stretcher.position - expected) <= Double(stretcher.framesPerIteration) * speed + 1)
        }
    }
}

@Test func aSineKeepsItsPitchAtHalfAndAtOneAndAHalfSpeed() {
    let rate = 48_000.0
    let take = sine(hz: 440, seconds: 6, rate: rate)

    withTake(left: take) { input in
        for speed in [0.5, 1.5] {
            let stretcher = TimeStretcher(sampleRate: rate, maxBlockFrames: 512)
            stretcher.speed = speed
            stretcher.reset(at: 0, input: input)

            let out = render(stretcher, frames: Int(2 * rate), block: 128, input: input)
            // The first window in, the second second out: settled.
            let measured = crossingsPerSecond(out.left[Int(rate) ..< Int(2 * rate)], rate: rate) / 2

            #expect(abs(measured - 440) < 440 * 0.02, "speed \(speed): \(measured) Hz")
            #expect(out.left.allSatisfy { $0.isFinite && abs($0) <= 1.0001 })
        }
    }
}

@Test func theStretchIsContinuousAcrossTheJoins() {
    // A slowed sine has no jumps larger than one input step would make.
    let rate = 48_000.0
    let take = sine(hz: 220, seconds: 4, rate: rate)

    withTake(left: take) { input in
        let stretcher = TimeStretcher(sampleRate: rate, maxBlockFrames: 512)
        stretcher.speed = 0.5
        stretcher.reset(at: 0, input: input)

        let out = render(stretcher, frames: Int(rate), block: 480, input: input).left
        let maxStep = Float(2 * .pi * 220 / rate) * 1.5

        for i in 1..<out.count {
            #expect(abs(out[i] - out[i - 1]) <= maxStep, "frame \(i)")
            if abs(out[i] - out[i - 1]) > maxStep { break }
        }
    }
}

@Test func inputWrapsIntoTheLoop() {
    let take: [Float] = (0..<1_000).map { Float($0) }
    let loop = LoopWindow(start: 100, end: 200)!

    withTake(left: take, loop: loop) { input in
        #expect(input.sample(0, at: 150) == 150)
        #expect(input.sample(0, at: 200) == 100)
        #expect(input.sample(0, at: 250) == 150)
        #expect(input.sample(0, at: 50) == 50)
        #expect(input.sample(0, at: -1) == 0)
    }

    withTake(left: take) { input in
        #expect(input.sample(0, at: 1_000) == 0, "past the take without a loop is silence")
        #expect(input.sample(1, at: 999) == 999, "a mono take answers for its right channel")
    }
}

@Test func thePositionWrapsIntoTheLoop() {
    let take = [Float](repeating: 0.5, count: 100_000)
    let loop = LoopWindow(start: 20_000, end: 30_000)!

    withTake(left: take, loop: loop) { input in
        let stretcher = TimeStretcher(sampleRate: 48_000, maxBlockFrames: 512)
        stretcher.speed = 0.5
        stretcher.reset(at: 29_000, input: input)

        _ = render(stretcher, frames: 48_000, block: 512, input: input)

        #expect(stretcher.position >= 20_000 && stretcher.position < 30_000)
    }
}

@Test func fractionalLoopArithmeticMatchesTheIntegerOne() {
    let loop = LoopWindow(start: 1_000, end: 2_000)!

    #expect(loop.wrapped(1_999.5) == 1_999.5)
    #expect(loop.wrapped(2_000.0) == 1_000)
    #expect(abs(loop.wrapped(2_030.25) - 1_030.25) < 1e-9)
    #expect(loop.wrapped(500.5) == 500.5)

    let crossing = loop.advance(from: 1_990, span: 64.5)
    #expect(crossing.renderEnd == 2_000)
    #expect(abs(crossing.next - 1_054.5) < 1e-9)

    let past = loop.advance(from: 2_500.5, span: 64)
    #expect(past.renderEnd == 2_564.5)
    #expect(past.next == 1_000)
}
