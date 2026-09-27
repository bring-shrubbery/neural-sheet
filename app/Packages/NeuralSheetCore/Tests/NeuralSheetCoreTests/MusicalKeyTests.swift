import Foundation
import Testing

@testable import NeuralSheetCore

@Test func keysAreSpelledByTheirSignature() {
    #expect(MusicalKey(tonic: 0, mode: .major).fifths == 0)
    #expect(MusicalKey(tonic: 7, mode: .major).fifths == 1)
    #expect(MusicalKey(tonic: 6, mode: .major).fifths == 6)
    #expect(MusicalKey(tonic: 5, mode: .major).fifths == -1)
    #expect(MusicalKey(tonic: 1, mode: .major).name == "D♭ major")
    #expect(MusicalKey(tonic: 1, mode: .minor).name == "C♯ minor")
    #expect(MusicalKey(tonic: 3, mode: .minor).fifths == -6)
    #expect(MusicalKey(tonic: 3, mode: .minor).name == "E♭ minor")
    #expect(MusicalKey(tonic: 9, mode: .minor).fifths == 0)
    #expect(MusicalKey(tonic: 10, mode: .minor).name == "B♭ minor")
    #expect(MusicalKey(tonic: 8, mode: .minor).name == "G♯ minor")
    #expect(MusicalKey(tonic: -3, mode: .major).tonic == 9, "the tonic wraps")

    // Every signature is a whole number of sharps or flats within the seven each way.
    for tonic in 0..<12 {
        for mode in MusicalKey.Mode.allCases {
            #expect(abs(MusicalKey(tonic: tonic, mode: mode).fifths) <= 6)
        }
    }

    #expect(MusicalKey.tonicMenuName(0) == "C")
    #expect(MusicalKey.tonicMenuName(1) == "C♯ / D♭")
}

@Test func theScaleAndItsNearestDegrees() {
    let cMajor = MusicalKey(tonic: 0, mode: .major)
    #expect(cMajor.scalePitchClasses == [0, 2, 4, 5, 7, 9, 11])
    #expect(cMajor.contains(pitch: 60))
    #expect(!cMajor.contains(pitch: 61))
    #expect(cMajor.isTonic(pitch: 72))
    #expect(cMajor.nearestScalePitch(61) == 60, "between two degrees, the lower")
    #expect(cMajor.nearestScalePitch(66) == 65)
    #expect(cMajor.nearestScalePitch(70) == 69)
    #expect(cMajor.nearestScalePitch(64) == 64)

    let aMinor = MusicalKey(tonic: 9, mode: .minor)
    #expect(aMinor.scalePitchClasses == [0, 2, 4, 5, 7, 9, 11], "the relative minor shares the scale")

    let eFlatMinor = MusicalKey(tonic: 3, mode: .minor)
    #expect(eFlatMinor.scalePitchClasses == [1, 3, 5, 6, 8, 10, 11])
    #expect(eFlatMinor.nearestScalePitch(60) == 59)
}

private func note(_ pitch: Int, at start: Double, length: Double = 0.5, program: Int = 0) -> NoteEvent {
    NoteEvent(startTime: start, endTime: start + length, pitch: pitch, program: program)
}

@Test func theEstimatorHearsAMajorScaleAndAMinorSong() {
    let scale = [60, 62, 64, 65, 67, 69, 71, 72].enumerated().map { note($1, at: Double($0) * 0.5) }
    #expect(KeyEstimator.estimate(notes: scale) == MusicalKey(tonic: 0, mode: .major))

    // A minor leaning on its tonic and the raised leading note: A C E A G♯ A, the tonic long.
    let minor = [
        note(57, at: 0, length: 2), note(60, at: 2), note(64, at: 2.5), note(57, at: 3, length: 1.5),
        note(68, at: 4.5), note(57, at: 5, length: 2), note(64, at: 7), note(60, at: 7.5), note(57, at: 8, length: 2),
    ]
    #expect(KeyEstimator.estimate(notes: minor) == MusicalKey(tonic: 9, mode: .minor))

    // Transposed up a fourth, the same song is in D minor.
    let dMinor = minor.map { NoteEvent(startTime: $0.startTime, endTime: $0.endTime, pitch: $0.pitch + 5, program: 0) }
    #expect(KeyEstimator.estimate(notes: dMinor) == MusicalKey(tonic: 2, mode: .minor))
}

@Test func theEstimatorIgnoresDrumsAndNeedsANote() {
    #expect(KeyEstimator.estimate(notes: []) == nil)
    #expect(KeyEstimator.estimate(notes: [note(36, at: 0, program: NoteEvent.drumProgram)]) == nil)
    #expect(KeyEstimator.estimate(notes: [note(60, at: 0, length: 0)]) == nil, "a note with no length weighs nothing")
}

@Test func snapToScaleMovesStrayNotesAndLeavesTheDrums() {
    let document = NoteDocument(events: [
        note(61, at: 0), note(64, at: 0.5), note(66, at: 1), note(42, at: 1.5, program: NoteEvent.drumProgram),
    ])
    let all = Set(document.notes.map(\.id))
    let batch = document.snapToScale(all, key: MusicalKey(tonic: 0, mode: .major))

    #expect(batch.title == "Snap to Scale")
    #expect(batch.changed.count == 2)
    #expect(Set(batch.changed.map(\.after.note.pitch)) == [60, 65])
    #expect(batch.inserted.isEmpty && batch.deleted.isEmpty)

    var applied = document
    applied.commit(batch)
    #expect(applied.events.map(\.pitch) == [60, 64, 65, 42])
    applied.undo()
    #expect(applied.events == document.events)
}

@Test func aProjectWithoutAKeyOpensWithNone() throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("nokey-\(UUID().uuidString).json")
    defer { try? FileManager.default.removeItem(at: url) }

    try Data("{\"formatVersion\": 1}".utf8).write(to: url)
    #expect(try ProjectState.read(from: url).key == nil)

    var state = ProjectState()
    state.key = MusicalKey(tonic: 6, mode: .major)
    try state.save(to: url)
    #expect(try ProjectState.read(from: url).key == MusicalKey(tonic: 6, mode: .major))
}
