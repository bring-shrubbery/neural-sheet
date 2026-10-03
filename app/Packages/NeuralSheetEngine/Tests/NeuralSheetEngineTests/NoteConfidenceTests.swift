// Per-note confidence (confidence design §2, §3): the probabilities `generate` returns,
// combined by the tracker into one number per onset, carried by the assembler to the
// note. Hand-built token streams, so it runs with no weights.

import Foundation
import Testing

@testable import NeuralSheetEngine

/// Single-precision arithmetic on both sides, so not the time tolerance.
private let confidenceTolerance: Float = 1e-6

/// Feeds `(token, probability)` pairs after a boundary at 0 and the tie that ends the
/// prologue, and returns every action.
private func actions(_ stream: [(Int32, Float)], tracker: inout OpenNoteTracker) -> [NoteAction] {
    var actions = tracker.feed(boundary: ChunkBoundary(seekTime: 0, nextSeekTime: nil))
    actions += tracker.feed(token: tokenID(.tie), probability: 1)

    for (token, probability) in stream {
        actions += tracker.feed(token: token, probability: probability)
    }

    return actions
}

@Test func aMelodicOnsetIsTheGeometricMeanOfProgramVelocityAndPitch() throws {
    var tracker = OpenNoteTracker()
    let got = actions([
        (tokenID(.shift, 10), 1), (tokenID(.program, 0), 0.9), (tokenID(.velocity, 1), 0.8),
        (tokenID(.pitch, 60), 0.5),
    ], tracker: &tracker)

    let start = try #require(got.first { $0.kind == .start })
    let expected = Float(pow(0.9 * 0.8 * 0.5, 1.0 / 3))
    #expect(abs(start.confidence - expected) <= confidenceTolerance)
}

@Test func aShiftLeavesTheProgramOutButKeepsTheVelocity() throws {
    // The program token belongs to the event it was emitted in; the velocity register
    // is a flag that stays set, so the token that set it still vouches for the note.
    var tracker = OpenNoteTracker()
    let got = actions([
        (tokenID(.shift, 10), 1), (tokenID(.program, 0), 0.9), (tokenID(.velocity, 1), 0.8),
        (tokenID(.pitch, 60), 1),
        (tokenID(.shift, 20), 0.1), (tokenID(.pitch, 62), 0.5),
    ], tracker: &tracker)

    let second = try #require(got.last { $0.kind == .start })
    #expect(second.pitch == 62)
    #expect(abs(second.confidence - (0.8 * 0.5).squareRoot()) <= confidenceTolerance)
}

@Test func aDrumHitIsItsDrumTokensProbability() throws {
    var tracker = OpenNoteTracker()
    let got = actions([
        (tokenID(.shift, 10), 1), (tokenID(.program, 0), 0.2), (tokenID(.velocity, 1), 0.2),
        (tokenID(.drum, 36), 0.4),
    ], tracker: &tracker)

    let hit = try #require(got.first { $0.kind == .drumHit })
    #expect(hit.confidence == 0.4)
}

@Test func promptTokensCountAsSure() throws {
    // A stream spelled entirely from prompt tokens, which `generate` returns at 1.
    var tracker = OpenNoteTracker()
    let got = actions([
        (tokenID(.shift, 10), 1), (tokenID(.program, 0), 1), (tokenID(.velocity, 1), 1),
        (tokenID(.pitch, 60), 1),
    ], tracker: &tracker)

    #expect(try #require(got.first { $0.kind == .start }).confidence == 1)
}

@Test func aNoteCarriedOverABoundaryKeepsTheConfidenceItOpenedWith() throws {
    var tracker = OpenNoteTracker()
    var assembler = NoteAssembler()

    _ = tracker.feed(boundary: ChunkBoundary(seekTime: 0, nextSeekTime: 5))

    for (token, probability) in [
        (tokenID(.tie), Float(1)), (tokenID(.shift, 450), 1), (tokenID(.program, 0), 0.9),
        (tokenID(.velocity, 1), 0.8), (tokenID(.pitch, 60), 0.5),
    ] {
        try assembler.apply(tracker.feed(token: token, probability: probability), chunkIndex: 0)
    }

    // The next chunk's forced prologue re-declares the note at probability 1; it is the
    // same note, not a new onset, so it keeps chunk 0's number.
    try assembler.apply(tracker.feed(boundary: ChunkBoundary(seekTime: 5, nextSeekTime: nil)), chunkIndex: 1)

    for token in Vocabulary.tieSectionTokenIDs(openKeys: tracker.openKeys) {
        try assembler.apply(tracker.feed(token: token, probability: 1), chunkIndex: 1)
    }

    try assembler.apply(tracker.feed(token: tokenID(.shift, 50), probability: 1), chunkIndex: 1)
    try assembler.apply(tracker.feed(token: tokenID(.velocity, 0), probability: 1), chunkIndex: 1)
    try assembler.apply(tracker.feed(token: tokenID(.pitch, 60), probability: 1), chunkIndex: 1)
    try assembler.apply(tracker.finish(), chunkIndex: 1)

    let notes = assembler.finalize()
    #expect(notes.count == 1)

    let note = try #require(notes.first)
    #expect(note.onset == 4.5 && note.offset == 5.5)
    #expect(abs(note.confidence - Float(pow(0.9 * 0.8 * 0.5, 1.0 / 3))) <= confidenceTolerance)
}

@Test func cleanupKeepsConfidence() {
    // validate widens and trim truncates; neither rebuilds a note, so neither loses it.
    let notes = NoteAssembler.trimOverlapping([
        Note(onset: 1.0, offset: 2.0, pitch: 60, program: 0, isDrum: false, confidence: 0.3),
        Note(onset: 1.5, offset: 2.5, pitch: 60, program: 0, isDrum: false, confidence: 0.7),
    ])

    #expect(notes.map(\.confidence) == [0.3, 0.7])
}

@Test func logSumExpMatchesTheNaiveSum() {
    let logits: [Float] = [1.5, -2, 0.25, 3, -0.5]
    let naive = log(logits.map { exp($0) }.reduce(0, +))

    #expect(abs(Model.logSumExp(logits) - naive) <= 1e-5)
}

@Test func logSumExpNeitherOverflowsNorTripsOnAMask() {
    // exp(1000) is infinity in single precision; the running maximum never takes it.
    #expect(abs(Model.logSumExp([1000, 1000]) - (1000 + log(2))) <= 1e-3)
    #expect(abs(Model.logSumExp([-Float.infinity, 0, -Float.infinity]) - 0) <= 1e-6)
    #expect(Model.logSumExp([-Float.infinity, -Float.infinity]) == -Float.infinity)
    #expect(Model.logSumExp([]) == -Float.infinity)
}

@Test func probabilityIsTheSoftmaxAtTheToken() {
    let logits: [Float] = [0, log(3), -Float.infinity]

    #expect(abs(Model.probability(of: 1, in: logits) - 0.75) <= 1e-6)
    #expect(Model.probability(of: 2, in: logits) == 0)
    #expect(Model.probability(of: 7, in: logits) == 0)
    #expect(Model.probability(of: 0, in: [-Float.infinity]) == 0)
}
