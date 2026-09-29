// The whole engine against the C++ engine's own output: the four variants of
// muscriptor.cpp's docs/TESTING.md, note for note, plus the streaming contract the app
// draws the piano roll from. Nothing below this level can be wrong while these pass, and
// nothing above it exists -- this is the port's acceptance test.
//
// Every test here skips without the `small` checkpoint; the package never downloads a
// model, so a clean checkout must still be able to run the suite offline. Each variant
// decodes all three chunks of the fixture, so this is the slowest suite in the package.

import Foundation
import Testing

@testable import NeuralSheetEngine

@Suite struct TranscriberOracleTests {
    /// One `notes_<variant>.json` dump: the arguments the oracle ran with, the notes it
    /// returned and the shape of the updates it streamed.
    private struct Oracle {
        var instruments: [InstrumentGroup]
        var preludeForcing: Bool
        var notes: [Note]
        var updates: [(finalizedThrough: Double, progress: Float, newNotes: Int)]
    }

    /// Reads a variant's dump, or nil when the fixtures are not in the bundle, which is
    /// the same skip the missing checkpoint takes.
    private static func oracle(_ variant: String) -> Oracle? {
        guard let root = try? Fixtures.json("oracle/small-cpu/notes_\(variant).json") as? [String: Any],
            let names = root["instruments"] as? [String],
            let preludeForcing = root["prelude_forcing"] as? Bool,
            let notes = root["notes"] as? [[String: Any]],
            let updates = root["updates"] as? [[String: Any]]
        else {
            return nil
        }

        let groups = names.compactMap { InstrumentGroups.group(forName: $0) }

        guard groups.count == names.count else { return nil }

        return Oracle(
            instruments: groups,
            preludeForcing: preludeForcing,
            notes: notes.map { note in
                Note(
                    onset: (note["onset"] as? NSNumber)?.doubleValue ?? .nan,
                    offset: (note["offset"] as? NSNumber)?.doubleValue ?? .nan,
                    pitch: (note["pitch"] as? NSNumber)?.intValue ?? -1,
                    program: (note["program"] as? NSNumber)?.intValue ?? -1,
                    isDrum: (note["is_drum"] as? NSNumber)?.boolValue ?? false)
            },
            // `progress` was printed from a C++ `float`, so it is read back as one:
            // widening the decimal to `Double` first and comparing there would fail on
            // the ninth digit for a reason that has nothing to do with the engine.
            updates: updates.map { update in
                (
                    finalizedThrough: (update["finalized_through"] as? NSNumber)?.doubleValue ?? .nan,
                    progress: (update["progress"] as? NSNumber)?.floatValue ?? .nan,
                    newNotes: (update["new_notes"] as? NSNumber)?.intValue ?? -1
                )
            })
    }

    /// A CPU transcriber over the small checkpoint and the fixture audio, or nil when the
    /// machine has no weights installed.
    private func setUp() throws -> (transcriber: Transcriber, audio: [Float])? {
        guard let checkpoint = Checkpoints.url(for: .small) else { return nil }
        guard let audio = try? Fixtures.fixtureAudio() else { return nil }

        return (try Transcriber(url: checkpoint, options: LoadOptions(useGPU: false)), audio)
    }

    /// Runs one variant and compares both halves of what it produced. `instruments` is
    /// stated by the caller rather than taken from the dump, and checked against the
    /// dump's names, so the selection's order is pinned by the test and not by the JSON.
    private func expectVariant(
        _ variant: String, instruments: [InstrumentGroup], preludeForcing: Bool
    ) throws -> [Note]? {
        guard let oracle = TranscriberOracleTests.oracle(variant) else { return nil }
        #expect(oracle.instruments == instruments, "\(variant): the dump's selection")
        #expect(oracle.preludeForcing == preludeForcing, "\(variant): the dump's prelude forcing")

        guard let (transcriber, audio) = try setUp() else { return nil }

        var updates: [TranscriptionUpdate] = []

        let notes = try transcriber.transcribe(
            samples: audio,
            options: TranscribeOptions(instruments: instruments, preludeForcing: preludeForcing)
        ) { update in
            updates.append(update)
            return true
        }

        expect(notes, match: oracle.notes, variant)
        expect(updates, match: oracle.updates, variant)
        return notes
    }

    /// Notes compare field by field rather than by `==`: the times are sums of a `double`
    /// tick count and a chunk offset, so they can land a rounding step from the dump's
    /// nine printed digits, while pitch, program and the drum flag are integers and must
    /// be identical.
    private func expect(_ notes: [Note], match expected: [Note], _ label: String) {
        #expect(notes.count == expected.count, "\(label): note count")

        for (index, pair) in zip(notes, expected).enumerated() {
            let (got, want) = pair
            #expect(got.pitch == want.pitch, "\(label) note \(index): pitch")
            #expect(got.program == want.program, "\(label) note \(index): program")
            #expect(got.isDrum == want.isDrum, "\(label) note \(index): is_drum")
            #expect(
                abs(got.onset - want.onset) <= 1e-9,
                "\(label) note \(index): onset \(got.onset) / \(want.onset)")
            #expect(
                abs(got.offset - want.offset) <= 1e-9,
                "\(label) note \(index): offset \(got.offset) / \(want.offset)")
        }
    }

    private func expect(
        _ updates: [TranscriptionUpdate],
        match expected: [(finalizedThrough: Double, progress: Float, newNotes: Int)],
        _ label: String
    ) {
        #expect(updates.count == expected.count, "\(label): update count")

        for (index, pair) in zip(updates, expected).enumerated() {
            let (got, want) = pair
            #expect(
                got.finalizedThrough == want.finalizedThrough,
                "\(label) update \(index): finalized_through")
            #expect(abs(got.progress - want.progress) <= 1e-6, "\(label) update \(index): progress")
            #expect(got.newNotes.count == want.newNotes, "\(label) update \(index): new_notes")
        }
    }

    @Test func plainVariantMatches() throws {
        _ = try expectVariant("plain", instruments: [], preludeForcing: false)
    }

    @Test func preludeVariantMatches() throws {
        // The default options, i.e. what the app runs.
        _ = try expectVariant("prelude", instruments: [], preludeForcing: true)
    }

    @Test func bassVariantMatches() throws {
        guard let notes = try expectVariant("bass", instruments: [.electricBass], preludeForcing: true) else {
            return
        }

        // A selection forbids every other instrument's tokens, so nothing else can come
        // out: the mask is what this variant is for.
        #expect(!notes.isEmpty)
        #expect(notes.allSatisfy { $0.program == 33 })
    }

    @Test func bandVariantMatches() throws {
        _ = try expectVariant(
            "band",
            instruments: [.distortedElectricGuitar, .synthLead, .electricBass, .drums, .voice],
            preludeForcing: true)
    }

    @Test func streamedNotesConcatenateToTheResult() throws {
        guard let (transcriber, audio) = try setUp() else { return }

        var streamed: [Note] = []

        let notes = try transcriber.transcribe(samples: audio) { update in
            streamed.append(contentsOf: update.newNotes)
            return true
        }

        // The updates are the same notes in a different order -- each chunk's own, in its
        // own window -- so sorting them the way `finalize` sorts must give the result
        // exactly. This is the promise a host streams against.
        NoteAssembler.sort(&streamed)
        #expect(streamed == notes)
    }

    @Test func anEmptySignalGivesNoNotesAndNoCalls() throws {
        guard let (transcriber, _) = try setUp() else { return }

        var calls = 0
        let notes = try transcriber.transcribe(samples: []) { _ in
            calls += 1
            return true
        }

        // Zero chunks: neither the per-chunk callback nor the closing one fires, which is
        // what lets a host treat "no update at all" as "nothing to draw".
        #expect(notes.isEmpty)
        #expect(calls == 0)
    }

    @Test func cancellationStopsAfterOneChunk() throws {
        guard let (transcriber, audio) = try setUp() else { return }

        var calls = 0

        #expect(throws: TranscriberError.cancelled) {
            try transcriber.transcribe(samples: audio) { _ in
                calls += 1
                return false
            }
        }

        #expect(calls == 1)
    }

    @Test func duplicateGroupsCollapse() throws {
        guard let oracle = TranscriberOracleTests.oracle("bass") else { return }
        guard let (transcriber, audio) = try setUp() else { return }

        // A repeated group must not add a second conditioning row: that would lengthen the
        // prefix, shift every position and change the tokens. So this is the bass variant.
        let notes = try transcriber.transcribe(
            samples: audio, options: TranscribeOptions(instruments: [.electricBass, .electricBass]))

        expect(notes, match: oracle.notes, "bass (duplicated)")
    }

    @Test func backendNameIsCPU() throws {
        guard let (transcriber, _) = try setUp() else { return }
        #expect(transcriber.backendName == "CPU")
    }
}
