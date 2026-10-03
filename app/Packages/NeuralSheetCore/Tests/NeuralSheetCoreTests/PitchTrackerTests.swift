import Foundation
import Testing

@testable import NeuralSheetCore

// The pitch tracker on synthetic signals (pitch curves design §3): a glide, a vibrato, noise and
// a note too short to measure.

private let rate = PitchTracker.sampleRate

/// A sine whose frequency at each sample is `frequency(t)`, phase accumulated so a changing
/// frequency has no clicks.
private func sine(seconds: Double, frequency: (Double) -> Double) -> [Float] {
    var phase = 0.0

    return (0..<Int(seconds * rate)).map { index in
        let value = Float(0.5 * sin(phase))
        phase += 2 * Double.pi * frequency(Double(index) / rate) / rate
        return value
    }
}

private func melodic(_ start: Double, _ end: Double, pitch: Int = 69) -> NoteEvent {
    NoteEvent(startTime: start, endTime: end, pitch: pitch, program: 0)
}

@Test func aGlideFromA4ToBFlat4RisesToAHundredCents() throws {
    // Steady 440 Hz, a linear glide to 466.16 Hz (+100 ¢) over 0.5 s, then steady again.
    let target = 440 * pow(2, 1.0 / 12)
    let samples = sine(seconds: 1.2) { t in
        t < 0.35 ? 440 : t < 0.85 ? 440 + (target - 440) * (t - 0.35) / 0.5 : target
    }

    let curve = try #require(PitchTracker.track(note: melodic(0.1, 1.1), mono16k: samples))

    #expect(curve.count == 100)
    // Frame i is at 0.1 + 0.01 i: steady before frame 25, gliding to frame 75, steady after.
    let start = curve[5..<20].reduce(0, +) / 15
    let end = curve[80..<95].reduce(0, +) / 15
    let middle = curve[50]
    print("glide: start \(start) ¢, middle \(middle) ¢ (expect ≈ 50), end \(end) ¢")
    #expect(abs(start) <= 10)
    #expect(abs(end - 100) <= 10)
    #expect(abs(middle - 50) <= 10)
    #expect(curve[30] < curve[50] && curve[50] < curve[70])
}

@Test func aSixHertzVibratoShowsItsExcursion() throws {
    // ±50 ¢ around A4 at 6 Hz.
    let samples = sine(seconds: 1.2) { t in 440 * pow(2, 50 * sin(2 * Double.pi * 6 * t) / 1200) }

    let curve = try #require(PitchTracker.track(note: melodic(0.1, 1.1), mono16k: samples))
    let high = curve.max() ?? 0
    let low = curve.min() ?? 0

    print("vibrato: max \(high) ¢, min \(low) ¢ (expect ±50)")
    #expect(abs(high - 50) <= 10)
    #expect(abs(low + 50) <= 10)
}

@Test func aHeldNoteIsNearlyFlat() throws {
    let samples = sine(seconds: 1) { _ in 440 }
    let curve = try #require(PitchTracker.track(note: melodic(0.1, 0.9), mono16k: samples))

    #expect(curve.allSatisfy { abs($0) < 3 })
}

@Test func aNoteWithHarmonicsAtAnotherPitchTracksToo() throws {
    // C4 with five harmonics at 1/h, 30 ¢ sharp: what a voice looks like more than a sine does.
    let f0 = 261.63 * pow(2, 30.0 / 1200)
    let samples = (0..<Int(rate)).map { index -> Float in
        let t = Double(index) / rate
        return Float((1...5).reduce(0.0) { $0 + 0.2 / Double($1) * sin(2 * Double.pi * Double($1) * f0 * t) })
    }

    let curve = try #require(PitchTracker.track(note: melodic(0.1, 0.9, pitch: 60), mono16k: samples))

    #expect(curve.allSatisfy { abs($0 - 30) < 5 })
}

@Test func whiteNoiseGivesNoCurve() {
    var generator = SystemRandomNumberGenerator()
    let samples = (0..<Int(rate)).map { _ in Float.random(in: -0.5...0.5, using: &generator) }

    #expect(PitchTracker.track(note: melodic(0.1, 0.9), mono16k: samples) == nil)
}

@Test func aNoteBuriedInAChordGivesNoCurve() {
    // A4 under a louder C major triad of harmonic tones: a mix, where the gate prefers nothing.
    let chord = [261.63, 329.63, 392.0]
    let samples = (0..<Int(rate)).map { index -> Float in
        let t = Double(index) / rate
        let triad = chord.reduce(0.0) { sum, f in
            sum + (1...5).reduce(0.0) { $0 + 0.3 / Double($1) * sin(2 * Double.pi * Double($1) * f * t) }
        }
        return Float(triad + 0.1 * sin(2 * Double.pi * 440 * t))
    }

    #expect(PitchTracker.track(note: melodic(0.1, 0.9), mono16k: samples) == nil)
}

@Test func silenceGivesNoCurve() {
    #expect(PitchTracker.track(note: melodic(0.1, 0.9), mono16k: [Float](repeating: 0, count: 16_000)) == nil)
}

@Test func aFiftyMillisecondNoteGivesNoCurve() {
    let samples = sine(seconds: 1) { _ in 440 }

    #expect(PitchTracker.track(note: melodic(0.2, 0.25), mono16k: samples) == nil)
    #expect(PitchTracker.track(note: melodic(0.2, 0.26), mono16k: samples) != nil)
}

@Test func drumsAndPitchesOutOfRangeAreLeftOut() {
    let samples = sine(seconds: 1) { _ in 440 }
    let notes = [
        EditableNote(id: NoteID(0), note: melodic(0.1, 0.9)),
        EditableNote(id: NoteID(1), note: NoteEvent(startTime: 0.1, endTime: 0.9, pitch: 38, program: NoteEvent.drumProgram)),
        EditableNote(id: NoteID(2), note: melodic(0.1, 0.9, pitch: 110)),
        EditableNote(id: NoteID(3), note: melodic(0.1, 0.12)),
    ]

    let curves = PitchTracker.track(notes: notes, mono16k: samples)

    #expect(Set(curves.keys) == [NoteID(0), NoteID(3)])
    #expect(curves[NoteID(0)]??.count == 80)
    // Present but nil: a re-track clears a curve the audio no longer gives.
    #expect(curves[NoteID(3)] == .some(nil))
}

@Test func aCancelledRunStopsBetweenNotes() {
    let samples = sine(seconds: 1) { _ in 440 }
    let notes = (0..<4).map { EditableNote(id: NoteID($0), note: melodic(0.1, 0.9)) }

    #expect(PitchTracker.track(notes: notes, mono16k: samples, isCancelled: { true }).isEmpty)
}

@Test func unreliableFramesAreFilledFromTheirNeighbours() {
    typealias Frame = PitchTracker.GoertzelBank.Frame
    let frames = [Frame(cents: 99, reliable: false), Frame(cents: 10, reliable: true),
                  Frame(cents: 99, reliable: false), Frame(cents: 30, reliable: true),
                  Frame(cents: 99, reliable: false)]

    #expect(PitchTracker.filled(frames) == [10, 10, 20, 30, 30])
}

@Test func sixtySecondsOfALineTrackInWellUnderASecond() {
    // 120 notes of half a second over two octaves, each a harmonic tone: a minute of vocal line.
    let pitches = (0..<120).map { 57 + ($0 * 7) % 24 }
    var samples = [Float](repeating: 0, count: Int(60 * rate))

    for (index, pitch) in pitches.enumerated() {
        let f0 = 440 * pow(2, Double(pitch - 69) / 12)
        let first = Int(Double(index) * 0.5 * rate)

        for n in 0..<Int(0.5 * rate) {
            let t = Double(n) / rate
            samples[first + n] = Float((1...3).reduce(0.0) { $0 + 0.2 / Double($1) * sin(2 * Double.pi * Double($1) * f0 * t) })
        }
    }

    let notes = pitches.enumerated().map { index, pitch in
        EditableNote(id: NoteID(index), note: melodic(Double(index) * 0.5, Double(index) * 0.5 + 0.5, pitch: pitch))
    }

    let clock = ContinuousClock()
    var curves: [NoteID: [Float]?] = [:]
    let elapsed = clock.measure { curves = PitchTracker.track(notes: notes, mono16k: samples) }

    let tracked = curves.values.compactMap { $0 }.count
    print("pitch tracker: 60 s of notes (\(notes.count) notes, 6000 frames) in \(elapsed), \(tracked) curves")
    #expect(tracked == notes.count)
    #expect(elapsed < .seconds(1))
}
