// The decoder for the `vectors/note_vectors.json` oracle, ported from
// muscriptor.cpp's cpp/tests/vectors.cpp so the Swift tests read the fixture the
// same way the reference's own tests do.
//
// The replay helpers live here rather than in either test file because the
// tracker tests and the assembler tests drive the identical loop: a disagreement
// between them would otherwise be a difference in the harness rather than in the
// code under test.

import Foundation

@testable import NeuralSheetEngine

/// One hand-authored vector: a token stream, and everything the reference decoded it to.
struct NoteVector {
    var name: String
    var seekTimes: [Double]
    var chunkTokens: [[Int32]]
    var openKeysAtBoundary: [[NoteKey]]
    var actions: [NoteAction]
    var notes: [Note]

    /// Boundaries from the seek times. The last chunk has no successor, which is what
    /// turns the window-drop rule off there.
    var boundaries: [ChunkBoundary] {
        seekTimes.indices.map { index in
            ChunkBoundary(
                seekTime: seekTimes[index],
                nextSeekTime: index + 1 < seekTimes.count ? seekTimes[index + 1] : nil)
        }
    }

    /// Every action the tracker answers with, in order, including `finish()`'s.
    func replayActions() -> [NoteAction] {
        var tracker = OpenNoteTracker()
        var actions: [NoteAction] = []

        for (chunk, boundary) in boundaries.enumerated() {
            actions += tracker.feed(boundary: boundary)

            for token in chunkTokens[chunk] {
                actions += tracker.feed(token: token)
            }
        }

        return actions + tracker.finish()
    }

    /// The same replay carried all the way to cleaned notes.
    func replayNotes() throws -> [Note] {
        var tracker = OpenNoteTracker()
        var assembler = NoteAssembler()
        let boundaries = self.boundaries

        for (chunk, boundary) in boundaries.enumerated() {
            try assembler.apply(tracker.feed(boundary: boundary), chunkIndex: chunk)

            for token in chunkTokens[chunk] {
                try assembler.apply(tracker.feed(token: token), chunkIndex: chunk)
            }
        }

        try assembler.apply(tracker.finish(), chunkIndex: boundaries.count - 1)
        return assembler.finalize()
    }
}

extension Fixtures {
    /// Every vector in the fixture, in file order.
    static func noteVectors() throws -> [NoteVector] {
        guard let data = try? Data(contentsOf: url("vectors/note_vectors.json")) else {
            throw FixtureError.missing("vectors/note_vectors.json")
        }

        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(RawVectorsFile.self, from: data).vectors.map { try $0.decoded() }
    }
}

private struct RawVectorsFile: Decodable {
    var vectors: [RawVector]
}

private struct RawVector: Decodable {
    var name: String
    var seekTimes: [Double]
    var chunkTokens: [[Int32]]
    var openKeysAtBoundary: [[[Int]]]
    var actions: [RawAction]
    var notes: [RawNote]

    func decoded() throws -> NoteVector {
        NoteVector(
            name: name,
            seekTimes: seekTimes,
            chunkTokens: chunkTokens,
            openKeysAtBoundary: try openKeysAtBoundary.map { keys in
                try keys.map { pair in
                    guard pair.count == 2 else {
                        throw FixtureError.malformed("vectors/note_vectors.json")
                    }

                    return NoteKey(program: pair[0], pitch: pair[1])
                }
            },
            actions: try actions.map { try $0.decoded() },
            notes: notes.map { $0.decoded() })
    }
}

private struct RawAction: Decodable {
    var kind: String
    var pitch: Int
    // Absent for a drum hit: the reference's `_DrumHit` carries only a pitch and a
    // time, and the tracker never consults the program register for one.
    var program: Int?
    var time: Double

    func decoded() throws -> NoteAction {
        switch kind {
        case "start":
            return NoteAction(kind: .start, program: program ?? 0, pitch: pitch, time: time)
        case "end":
            return NoteAction(kind: .end, program: program ?? 0, pitch: pitch, time: time)
        case "drum":
            return NoteAction(kind: .drumHit, program: 0, pitch: pitch, time: time)
        default:
            throw FixtureError.malformed("vectors/note_vectors.json")
        }
    }
}

private struct RawNote: Decodable {
    var onset: Double
    var offset: Double
    var pitch: Int
    var program: Int
    var isDrum: Bool

    func decoded() -> Note {
        Note(onset: onset, offset: offset, pitch: pitch, program: program, isDrum: isDrum)
    }
}
