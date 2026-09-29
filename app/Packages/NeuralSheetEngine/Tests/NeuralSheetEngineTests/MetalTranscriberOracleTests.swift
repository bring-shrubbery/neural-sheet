// The port's acceptance test again, on the GPU: the four variants of muscriptor.cpp's
// docs/TESTING.md note for note, against `oracle/small-metal/`. `MetalOracleTests` compares
// the forward pass and the token streams, which is where a kernel bug shows first, but the
// notes are what the app puts on the roll, and only this suite says that what comes out of
// the Metal backend is the same transcription -- including the streaming contract, where a
// chunk boundary is decided by the tokens and could in principle differ.
//
// Every test skips without a Metal device, the `small` checkpoint or the audio fixture. The
// suite is serialised for the same reason `MetalOracleTests` is: one GPU, and each test
// holds its own copy of the weights and the KV cache.

import Foundation
import Metal
import Testing

@testable import NeuralSheetEngine

@Suite(.serialized) struct MetalTranscriberOracleTests {
    /// A Metal transcriber over the small checkpoint and the fixture audio, or nil when the
    /// machine has no GPU or no weights installed.
    private func setUp() throws -> (transcriber: Transcriber, audio: [Float])? {
        guard MTLCreateSystemDefaultDevice() != nil else { return nil }
        guard let checkpoint = Checkpoints.url(for: .small) else { return nil }
        guard let audio = try? Fixtures.fixtureAudio() else { return nil }

        let transcriber = try Transcriber(url: checkpoint, options: LoadOptions(useGPU: true))

        // The point of every test below: a silent fall back to the CPU would make them all
        // pass while running the CPU suite a second time.
        #expect(transcriber.backendName == "Metal")
        return (transcriber, audio)
    }

    @Test func plainVariantMatches() throws {
        guard let (transcriber, audio) = try setUp() else { return }
        try OracleNotes.expectVariant(.plain, through: transcriber, samples: audio, from: "small-metal")
    }

    @Test func preludeVariantMatches() throws {
        // The default options, i.e. what the app runs.
        guard let (transcriber, audio) = try setUp() else { return }
        try OracleNotes.expectVariant(.prelude, through: transcriber, samples: audio, from: "small-metal")
    }

    @Test func bassVariantMatches() throws {
        guard let (transcriber, audio) = try setUp() else { return }

        guard let notes = try OracleNotes.expectVariant(
            .bass, through: transcriber, samples: audio, from: "small-metal")
        else {
            return
        }

        // A selection forbids every other instrument's tokens, so nothing else can come out:
        // the mask is a GPU kernel here, and this is what says it ran.
        #expect(!notes.isEmpty)
        #expect(notes.allSatisfy { $0.program == 33 })
    }

    @Test func bandVariantMatches() throws {
        guard let (transcriber, audio) = try setUp() else { return }
        try OracleNotes.expectVariant(.band, through: transcriber, samples: audio, from: "small-metal")
    }
}
