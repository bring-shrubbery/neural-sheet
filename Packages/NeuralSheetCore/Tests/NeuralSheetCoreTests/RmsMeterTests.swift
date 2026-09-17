import Foundation
import Testing

@testable import NeuralSheetCore

/// Pushes `samples` through the meter one buffer at a time, the way an audio callback would.
private func push(_ meter: inout RmsMeter, _ samples: [Float]) {
    samples.withUnsafeBufferPointer { meter.push($0) }
}

@Test func fullScaleSineReadsThreeDecibelsBelowPeak() {
    // 1 kHz at 48 kHz: 50 whole periods fill the 50 ms window exactly, so the mean square is 0.5.
    var meter = RmsMeter(sampleRate: 48_000)
    let sine = (0..<2400).map { Float(sin(2 * Double.pi * 1000 * Double($0) / 48_000)) }

    push(&meter, sine)

    #expect(abs(meter.decibels - (-3.0102999566)) < 0.001)
}

@Test func silenceReadsTheFloor() {
    var meter = RmsMeter(sampleRate: 48_000)

    #expect(meter.decibels == -100)

    push(&meter, [Float](repeating: 1, count: 2400))
    #expect(abs(meter.decibels) < 1e-9)

    // A full window of silence drains the sum to exactly zero rather than to rounding residue.
    meter.pushSilence(count: 2400)
    #expect(meter.decibels == -100)
}

@Test func silencePastAFullWindowStaysAtTheFloor() {
    var meter = RmsMeter(sampleRate: 48_000)

    push(&meter, [Float](repeating: 0.5, count: 2400))
    meter.pushSilence(count: 1_000_000)

    #expect(meter.decibels == -100)
}

@Test func theWindowSlidesOverTheLastFiftyMilliseconds() {
    var meter = RmsMeter(sampleRate: 48_000, windowSeconds: 0.05)

    #expect(meter.windowSamples == 2400)

    // Half a window of full scale after a silent start: mean square 0.5.
    push(&meter, [Float](repeating: 1, count: 1200))
    #expect(abs(meter.decibels - (-3.0102999566)) < 0.001)

    // The other half fills it, and the older silence has left the window.
    push(&meter, [Float](repeating: 1, count: 1200))
    #expect(abs(meter.decibels) < 1e-9)
}

@Test func aShortWindowStillHoldsOneSample() {
    var meter = RmsMeter(sampleRate: 48_000, windowSeconds: 0)

    #expect(meter.windowSamples == 1)

    push(&meter, [1.0])
    #expect(abs(meter.decibels) < 1e-9)
}
