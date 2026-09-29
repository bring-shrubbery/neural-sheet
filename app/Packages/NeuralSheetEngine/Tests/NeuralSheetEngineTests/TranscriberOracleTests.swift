// The whole engine against the C++ engine's own output: the four variants of
// muscriptor.cpp's docs/TESTING.md, note for note, plus the streaming contract the app
// draws the piano roll from. Nothing below this level can be wrong while these pass, and
// nothing above it exists -- this is the port's acceptance test.
//
// The dumps are read and compared by `Support/OracleNotes.swift`, which the Metal and the
// medium suites share: what a variant is run with, and what counts as a match, is stated
// once for all three.
//
// Every test here skips without the `small` checkpoint; the package never downloads a
// model, so a clean checkout must still be able to run the suite offline. Each variant
// decodes all three chunks of the fixture, so this is the slowest suite in the package.

import Foundation
import Testing

@testable import NeuralSheetEngine

@Suite struct TranscriberOracleTests {
    /// The oracle directory these tests compare against: the reference's CPU dump.
    private static let directory = "small-cpu"

    /// A CPU transcriber over the small checkpoint and the fixture audio, or nil when the
    /// machine has no weights installed.
    private func setUp() throws -> (transcriber: Transcriber, audio: [Float])? {
        guard let checkpoint = Checkpoints.url(for: .small) else { return nil }
        guard let audio = try? Fixtures.fixtureAudio() else { return nil }

        return (try Transcriber(url: checkpoint, options: LoadOptions(useGPU: false)), audio)
    }

    /// Runs one variant and compares the notes and the updates it produced. Returns nil
    /// when the fixtures or the weights are missing and the test skips.
    private func expectVariant(_ variant: OracleVariant) throws -> [Note]? {
        guard let (transcriber, audio) = try setUp() else { return nil }

        return try OracleNotes.expectVariant(
            variant, through: transcriber, samples: audio, from: TranscriberOracleTests.directory)
    }

    @Test func plainVariantMatches() throws {
        _ = try expectVariant(.plain)
    }

    @Test func preludeVariantMatches() throws {
        // The default options, i.e. what the app runs.
        _ = try expectVariant(.prelude)
    }

    @Test func bassVariantMatches() throws {
        guard let notes = try expectVariant(.bass) else { return }

        // A selection forbids every other instrument's tokens, so nothing else can come
        // out: the mask is what this variant is for.
        #expect(!notes.isEmpty)
        #expect(notes.allSatisfy { $0.program == 33 })
    }

    @Test func bandVariantMatches() throws {
        _ = try expectVariant(.band)
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
        guard let oracle = OracleNotes.load(.bass, from: TranscriberOracleTests.directory) else { return }
        guard let (transcriber, audio) = try setUp() else { return }

        // A repeated group must not add a second conditioning row: that would lengthen the
        // prefix, shift every position and change the tokens. So this is the bass variant.
        let notes = try transcriber.transcribe(
            samples: audio, options: TranscribeOptions(instruments: [.electricBass, .electricBass]))

        oracle.expect(notes, "bass (duplicated)")
    }

    @Test func backendNameIsCPU() throws {
        guard let (transcriber, _) = try setUp() else { return }
        #expect(transcriber.backendName == "CPU")
    }
}
