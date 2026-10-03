import Foundation
import Testing

@testable import NeuralSheetCore

// Detect's tempo map on synthetic click tracks (tempo map design §3).

/// 10 ms decaying bursts of a 2 kHz tone at 16 kHz, one per beat time, the first of every
/// `accentEvery` at twice the level; a second of silence after the last.
private func clicks(at times: [Double], accentEvery: Int = 4) -> [Float] {
    let rate = TempoEstimator.sampleRate
    var samples = [Float](repeating: 0, count: Int(((times.last ?? 0) + 1) * rate))
    let burst = Int(0.010 * rate)

    for (beat, time) in times.enumerated() {
        let start = Int(time * rate)
        let level: Float = beat % accentEvery == 0 ? 1.0 : 0.5

        for i in 0..<burst where start + i < samples.count {
            let t = Double(i) / rate
            samples[start + i] += level * Float(exp(-t * 400) * sin(2 * Double.pi * 2000 * t))
        }
    }

    return samples
}

/// Beat times from `start`, `count` beats at each tempo in turn.
private func beatTimes(start: Double, runs: [(bpm: Double, count: Int)]) -> [Double] {
    var times: [Double] = []
    var time = start

    for run in runs {
        for _ in 0..<run.count {
            times.append(time)
            time += 60 / run.bpm
        }
    }

    return times
}

@Test func aSteadyClickIsOneSegmentAtItsTempo() throws {
    let estimate = try #require(TempoEstimator.estimate(mono16k: clicks(at: beatTimes(start: 0.3, runs: [(120, 64)]))))

    #expect(estimate.segments.count == 1, "\(estimate.segments)")
    #expect(estimate.segments.first?.bpm == 120.0)
    #expect(abs(estimate.downbeatSeconds - 0.3) < 0.015, "\(estimate.downbeatSeconds)")
    #expect(estimate.timeSignature == .common, "a 4/4 accent is clear")
}

@Test func theTrackedBeatsLandOnTheClicks() {
    let times = beatTimes(start: 0.3, runs: [(120, 32), (90, 24)])
    let samples = clicks(at: times)
    let envelope = TempoEstimator.onsetEnvelope(samples)
    let bpm = TempoEstimator.tempo(from: envelope) ?? 0
    let beats = BeatTracker.track(envelope: envelope, bpm: bpm)

    #expect(beats.count == times.count, "\(beats.count) beats for \(times.count) clicks at \(bpm)")
    #expect(zip(beats, times).allSatisfy { abs($0 - $1) < 0.015 }, "\(zip(beats, times).map { $0 - $1 })")
}

@Test func aStepFrom120To90IsTwoSegments() throws {
    // Eight bars at 120, then eight at 90: the change falls on bar 9.
    let samples = clicks(at: beatTimes(start: 0.3, runs: [(120, 32), (90, 33)]))
    let estimate = try #require(TempoEstimator.estimate(mono16k: samples))

    #expect(estimate.segments.map(\.startBar) == [1, 9], "\(estimate.segments)")
    #expect(estimate.segments.count == 2 && abs(estimate.segments[0].bpm - 120) <= 0.2 && abs(estimate.segments[1].bpm - 90) <= 0.2,
            "\(estimate.segments.map(\.bpm))")
}

@Test func aSlowdownIsSegmentsEachSlowerThanTheLast() throws {
    // 26 bars slowing beat by beat from 132 to 84.
    let count = 104
    var times: [Double] = []
    var time = 0.4
    for beat in 0..<count {
        times.append(time)
        time += 60 / (132 - 48 * Double(beat) / Double(count - 1))
    }

    let estimate = try #require(TempoEstimator.estimate(mono16k: clicks(at: times)))
    let tempos = estimate.segments.map(\.bpm)

    #expect(tempos.count >= 3, "\(estimate.segments)")
    #expect(zip(tempos.dropFirst(), tempos).allSatisfy { $0 < $1 }, "\(tempos)")
    #expect((tempos.first ?? 0) > 120 && (tempos.last ?? 200) < 95, "\(tempos)")
}

@Test func aWaltzAccentReadsAsThreeFour() throws {
    let samples = clicks(at: beatTimes(start: 0.2, runs: [(132, 48)]), accentEvery: 3)
    let estimate = try #require(TempoEstimator.estimate(mono16k: samples))

    #expect(estimate.timeSignature == TimeSignature(numerator: 3, denominator: 4))
    #expect(estimate.segments.allSatisfy { $0.timeSignature.numerator == 3 })
    #expect(abs(estimate.downbeatSeconds - 0.2) < 0.015, "\(estimate.downbeatSeconds)")
}

@Test func aFlatClickSaysNothingAboutTheMeter() throws {
    let samples = clicks(at: beatTimes(start: 0.2, runs: [(110, 48)]), accentEvery: 1_000_000)
    let estimate = try #require(TempoEstimator.estimate(mono16k: samples))

    #expect(estimate.timeSignature == nil)

    // The meter it was given counts the bars instead.
    let counted = try #require(TempoEstimator.estimate(mono16k: samples, meter: TimeSignature(numerator: 3, denominator: 4)))
    #expect(counted.segments.allSatisfy { $0.timeSignature.numerator == 3 })
}

@Test func barsFoldIntoSegmentsWithinTwoPercent() throws {
    // Bars of 2 s (120), 2.02 s (118.8, within 2 %), then 2.4 s (100).
    let downbeats: [Double] = [1.0, 3.0, 5.02, 7.42, 9.82]
    var beats: [Double] = []
    for index in 0..<(downbeats.count - 1) {
        let length = downbeats[index + 1] - downbeats[index]
        for beat in 0..<4 {
            beats.append(downbeats[index] + Double(beat) * length / 4)
        }
    }
    beats.append(downbeats[downbeats.count - 1])
    let map = try #require(TempoMapBuilder.build(beats: [0.5] + beats, downbeatIndex: 1, timeSignature: .common))

    #expect(map.offset == 1)
    #expect(map.segments.map(\.startBar) == [1, 3])
    #expect(map.segments.map(\.bpm) == [119.4, 100])

    #expect(TempoMapBuilder.build(beats: Array(beats.prefix(5)), downbeatIndex: 0, timeSignature: .common) == nil,
            "one bar is too few")
}
