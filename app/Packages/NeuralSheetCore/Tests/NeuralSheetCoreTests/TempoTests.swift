import Foundation
import Testing

@testable import NeuralSheetCore

// MARK: - Tap tempo

@Test func fourEvenTapsGiveTheirTempo() {
    var taps = TapTempo()
    #expect(taps.tap(at: 10.0) == nil)
    #expect(taps.tap(at: 10.5) == 120)
    #expect(taps.tap(at: 11.0) == 120)
    #expect(taps.tap(at: 11.5) == 120)
}

@Test func theTempoIsTheMedianInterval() {
    var taps = TapTempo()
    _ = taps.tap(at: 0)
    _ = taps.tap(at: 0.5)
    _ = taps.tap(at: 1.02)
    _ = taps.tap(at: 1.5)
    // Intervals 0.5, 0.52, 0.48, 0.5: the median is 0.5.
    #expect(taps.tap(at: 2.0) == 120)
}

@Test func aGapOrADoublePressStartsOver() {
    var taps = TapTempo()
    _ = taps.tap(at: 0)
    _ = taps.tap(at: 0.5)
    #expect(taps.tap(at: 3.5) == nil, "a 3 s gap is not a beat")
    #expect(taps.tap(at: 4.0) == 120)

    _ = taps.tap(at: 4.1)
    #expect(taps.tap(at: 4.1) == nil, "a double-press is not a beat either")

    taps.reset()
    #expect(taps.tap(at: 100) == nil)
}

@Test func tapsOnTheTakeClockReadTheTakeTempoAtAnySpeed() {
    // At half speed the take's clock advances 0.5 s between beats of a 120 BPM take, just as
    // at full speed: the intervals are in take seconds either way.
    var taps = TapTempo()
    _ = taps.tap(at: 20.0)
    #expect(taps.tap(at: 20.5) == 120)
}

@Test func theTapTempoIsClampedToTheGrid() {
    var taps = TapTempo()
    _ = taps.tap(at: 0)
    #expect(taps.tap(at: 0.25) == 240)
    var slow = TapTempo()
    _ = slow.tap(at: 0)
    #expect(slow.tap(at: 2.0) == 30)
}

// MARK: - Tempo estimation

/// A click track at 16 kHz: 10 ms bursts of a 2 kHz tone, decaying, one per beat, every fourth
/// at twice the level.
private func clickTrack(bpm: Double, firstBeat: Double, seconds: Double, accentEvery: Int = 4) -> [Float] {
    let rate = TempoEstimator.sampleRate
    var samples = [Float](repeating: 0, count: Int(seconds * rate))
    let period = 60 / bpm
    let burst = Int(0.010 * rate)
    var beat = 0
    var time = firstBeat

    while time < seconds {
        let start = Int(time * rate)
        let level: Float = beat % accentEvery == 0 ? 1.0 : 0.5

        for i in 0..<burst where start + i < samples.count {
            let t = Double(i) / rate
            let decay = Float(exp(-t * 400))
            samples[start + i] += level * decay * Float(sin(2 * Double.pi * 2000 * t))
        }

        beat += 1
        time += period
    }

    return samples
}

/// Whether `a` is within `tolerance` of `b` plus some whole number of `period`s.
private func within(_ a: Double, of b: Double, modulo period: Double, tolerance: Double) -> Bool {
    let difference = (a - b).truncatingRemainder(dividingBy: period)
    let folded = min(abs(difference), period - abs(difference))
    return folded <= tolerance
}

@Test func aClickTrackAt120GivesItsTempoAndDownbeat() {
    let estimate = TempoEstimator.estimate(mono16k: clickTrack(bpm: 120, firstBeat: 0.3, seconds: 20))
    #expect(estimate?.bpm == 120)

    if let estimate {
        #expect(within(estimate.downbeatSeconds, of: 0.3, modulo: 2.0, tolerance: 0.015), "\(estimate.downbeatSeconds)")
        #expect(estimate.downbeatSeconds >= 0 && estimate.downbeatSeconds < 2.0 + 0.015, "the earliest downbeat")
    }
}

@Test func aClickTrackAt90GivesItsTempo() {
    let estimate = TempoEstimator.estimate(mono16k: clickTrack(bpm: 90, firstBeat: 0.1, seconds: 20))
    #expect(estimate?.bpm == 90)

    if let estimate {
        #expect(within(estimate.downbeatSeconds, of: 0.1, modulo: 60 / 90 * 4, tolerance: 0.015), "\(estimate.downbeatSeconds)")
    }
}

@Test func aFastClickTrackFoldsIntoTheRange() {
    // 100 BPM without accents: the beat is still found; the downbeat lands on some beat.
    let estimate = TempoEstimator.estimate(mono16k: clickTrack(bpm: 100, firstBeat: 0.5, seconds: 16, accentEvery: 1_000))
    #expect(estimate?.bpm == 100)

    if let estimate {
        #expect(within(estimate.downbeatSeconds, of: 0.5, modulo: 0.6, tolerance: 0.015), "\(estimate.downbeatSeconds)")
    }
}

@Test func silenceAndAShortTakeHaveNoTempo() {
    #expect(TempoEstimator.estimate(mono16k: [Float](repeating: 0, count: 16_000 * 10)) == nil)
    #expect(TempoEstimator.estimate(mono16k: clickTrack(bpm: 120, firstBeat: 0, seconds: 2)) == nil)
    #expect(TempoEstimator.estimate(mono16k: []) == nil)
}

@Test func theEnvelopePeaksOnTheClicks() {
    let envelope = TempoEstimator.onsetEnvelope(clickTrack(bpm: 120, firstBeat: 0.3, seconds: 5))
    let rate = TempoEstimator.envelopeRate
    #expect(envelope.count == (5 * 16_000 - 512) / 80 + 1)

    // The frame standing for 0.3 s -- the one whose window is centred there -- is a local
    // maximum against its surroundings a tenth of a second away.
    let onClick = envelope[Int((0.3 - TempoEstimator.frameCentreOffset) * rate)]
    let offClick = envelope[Int((0.4 - TempoEstimator.frameCentreOffset) * rate)]
    #expect(onClick > offClick * 4, "\(onClick) vs \(offClick)")
}
