import Foundation
import Testing

@testable import NeuralSheetCore

// The pitch curve in the document (pitch curves design §2, Curve lifetime): its file form, the
// Track Pitch landing, and which commands keep it and which drop it.

private let curve: [Float] = [0, 5, 10, 20, 30, 40, 50, 60, 70, 80]

private func curved(_ start: Double, _ end: Double, pitch: Int = 60) -> NoteEvent {
    NoteEvent(startTime: start, endTime: end, pitch: pitch, program: 0, pitchCurve: curve)
}

private func document(_ notes: NoteEvent...) -> (NoteDocument, Set<NoteID>) {
    let document = NoteDocument(events: notes)
    return (document, Set(document.notes.map(\.id)))
}

/// The curves on every note the batch leaves changed or inserted.
private func curves(_ batch: EditBatch) -> [[Float]?] {
    batch.changed.map(\.after.note.pitchCurve) + batch.inserted.map(\.note.pitchCurve)
}

@Test func aNoteWithoutACurveWritesNoKeyAndOldNotesReadNil() throws {
    let plain = NoteEvent(startTime: 0, endTime: 1, pitch: 60, program: 0)
    let text = String(decoding: try JSONEncoder().encode(plain), as: UTF8.self)
    #expect(!text.contains("pitchCurve"))

    let json = #"{"startTime":0,"endTime":1,"pitch":60,"amplitude":0.5,"program":0}"#
    #expect(try JSONDecoder().decode(NoteEvent.self, from: Data(json.utf8)).pitchCurve == nil)
}

@Test func aCurveRoundTripsThroughTheFile() throws {
    let note = curved(0, 0.1)
    let decoded = try JSONDecoder().decode(NoteEvent.self, from: JSONEncoder().encode(note))

    #expect(decoded == note)
    #expect(decoded.pitchCurve == curve)
}

@Test func setPitchCurvesChangesOnlyTheCurve() throws {
    let (document, _) = document(NoteEvent(startTime: 0, endTime: 0.1, pitch: 60, program: 0), curved(1, 1.1, pitch: 62))
    let ids = document.notes.map(\.id)

    let batch = document.setPitchCurves([ids[0]: curve, ids[1]: nil])

    #expect(batch.title == "Track Pitch")
    #expect(batch.changed.count == 2)
    #expect(batch.inserted.isEmpty && batch.deleted.isEmpty)
    for change in batch.changed {
        var before = change.before.note
        before.pitchCurve = change.after.note.pitchCurve
        #expect(before == change.after.note)
    }
    #expect(batch.changed.first { $0.after.id == ids[0] }?.after.note.pitchCurve == curve)
    #expect(batch.changed.first { $0.after.id == ids[1] }?.after.note.pitchCurve == nil)
}

@Test func setPitchCurvesSkipsNotesEditedSinceTheyWereMeasured() {
    let (document, _) = document(curved(0, 0.1), curved(1, 1.1, pitch: 62))
    let ids = document.notes.map(\.id)
    var measured = Dictionary(uniqueKeysWithValues: document.notes.map { ($0.id, $0.note) })
    measured[ids[0]]?.pitch = 59
    let fresh: [Float] = Array(repeating: 1, count: 10)

    let batch = document.setPitchCurves([ids[0]: fresh, ids[1]: fresh, NoteID(99): fresh], measuredOn: measured)

    #expect(batch.changed.map(\.after.id) == [ids[1]])
}

@Test func setPitchCurvesWithNothingNewIsEmpty() {
    let (document, ids) = document(curved(0, 0.1))

    #expect(document.setPitchCurves([ids.first!: curve]).isEmpty)
}

@Test func moveInTimeAndVelocityAndInstrumentKeepTheCurve() {
    let (document, ids) = document(curved(0, 0.1), curved(1, 1.1, pitch: 62))

    let batches = [
        document.move(ids, deltaSeconds: 0.37, deltaSemitones: 0),
        document.setStart(ids, seconds: 2),
        document.setVelocity(ids, velocity: 30),
        document.setVelocities(ids) { $0 / 2 },
        document.setProgram(ids, program: 40),
        document.quantize(ids, grid: TempoGrid(bpm: 120, offsetSeconds: 0.013, division: .sixteenth), lengths: false),
    ]

    for batch in batches {
        #expect(!batch.changed.isEmpty)
        #expect(curves(batch).allSatisfy { $0 == curve }, "\(batch.title)")
    }
}

@Test func pitchAndLengthEditsDropTheCurve() {
    let (document, ids) = document(curved(0, 0.1), curved(1, 1.1, pitch: 62))
    let key = MusicalKey(tonic: 0, mode: .major)

    let batches = [
        document.move(ids, deltaSeconds: 0, deltaSemitones: 1),
        document.setPitch(ids, pitch: 70),
        document.resize(ids, edge: .end, deltaSeconds: 0.05),
        document.resize(ids, edge: .start, deltaSeconds: 0.02),
        document.setLength(ids, seconds: 0.5),
        document.quantize(ids, grid: TempoGrid(bpm: 120, offsetSeconds: 0, division: .quarter), lengths: true),
        NoteDocument(events: [curved(0, 0.1, pitch: 61)]).snapToScale([NoteID(0)], key: key),
    ]

    for batch in batches {
        #expect(!batch.changed.isEmpty, "\(batch.title)")
        #expect(curves(batch).allSatisfy { $0 == nil }, "\(batch.title)")
    }
}

@Test func joinAndSplitDropTheCurve() {
    let (joinable, joinIDs) = document(curved(0, 0.1), curved(0.12, 0.3))
    let joined = joinable.join(joinIDs, gap: 0.05)
    #expect(joined.changed.count == 1)
    #expect(curves(joined) == [nil])

    var (splittable, splitIDs) = document(curved(0, 1))
    let split = splittable.split(splitIDs, at: 0.5).batch
    #expect(split.changed.count == 1 && split.inserted.count == 1)
    #expect(curves(split) == [nil, nil])
}

@Test func anOverlapTrimDropsTheTrimmedNotesCurve() {
    // Moving the second note onto the first trims the first, whose length then changes.
    let (document, _) = document(curved(0, 1), curved(2, 3, pitch: 62))
    let second = document.notes[1].id

    let batch = document.move([second], deltaSeconds: -1.5, deltaSemitones: -2)
    let trimmed = batch.changed.first { $0.after.id == document.notes[0].id }

    #expect(trimmed?.after.note.endTime == 0.5)
    #expect(trimmed?.after.note.pitchCurve == nil)
}

@Test func duplicatesAndPastesKeepTheCurveUnlessThePitchMoves() {
    var (document, ids) = document(curved(0, 0.1))

    #expect(curves(document.duplicate(ids, deltaSeconds: 1, deltaSemitones: 0)) == [curve])
    #expect(curves(document.duplicate(ids, deltaSeconds: 1, deltaSemitones: 3)) == [nil])
    #expect(curves(document.paste([curved(0, 0.1)], at: 4)) == [curve])
    #expect(curves(document.insert(curved(0, 0.1))) == [nil])
}

@Test func mergingOverlapsKeepsTheEarlierNotesCurve() {
    var later = curved(0.05, 0.3)
    later.pitchCurve = [1, 2, 3]

    let merged = mergeOverlappingNotesWithSamePitch([later, curved(0, 0.1)])

    #expect(merged.count == 1)
    #expect(merged[0].pitchCurve == curve)
    #expect(merged[0].endTime == 0.3)
}
