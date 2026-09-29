// Everything about `Transcriber` that needs no weights: the chunk arithmetic, the error
// vocabulary and the three ways loading a file that is not a usable checkpoint fails.
// The transcription itself is in TranscriberOracleTests, against the C++ engine's dumps.

import Foundation
import Testing

@testable import NeuralSheetEngine

@Suite struct TranscriberTests {
    @Test func chunkCountCoversAPartialTail() {
        // Ceiling division: a signal shorter than a segment is still one chunk, and one
        // sample past a segment boundary is a whole second chunk, zero-padded.
        #expect(Transcriber.chunkCount(sampleCount: 0) == 0)
        #expect(Transcriber.chunkCount(sampleCount: 1) == 1)
        #expect(Transcriber.chunkCount(sampleCount: 80_000) == 1)
        #expect(Transcriber.chunkCount(sampleCount: 80_001) == 2)
        #expect(Transcriber.chunkCount(sampleCount: 240_000) == 3)
    }

    @Test func theConstantsAreTheReferences() {
        #expect(Transcriber.sampleRate == 16_000)
        #expect(Transcriber.segmentSamples == 80_000)
        #expect(Transcriber.segmentDuration == 5.0)
        #expect(Transcriber.maxTokensPerChunk == 2000)
        #expect(Transcriber.checkpointFormatVersion == 1)

        // The KV cache the reference sizes: 501 mel frames, the dataset row, every
        // selectable instrument, the initial token and a chunk's tokens. It is derived
        // from the constants above, so this is what catches one of them moving.
        #expect(Transcriber.melFrames(hopLength: 160) == 501)
        #expect(Transcriber.requiredContextSize == 501 + 1 + 35 + 1 + 2000)
        #expect(Transcriber.requiredContextSize == 2538)
    }

    /// The strings a host logs, so they are pinned to the C++ `describe`'s wording rather
    /// than left to drift with whatever the payloads say.
    @Test func everyErrorDescribesItselfAsTheCppDoes() {
        #expect(TranscriberError.fileNotFound("x").description == "checkpoint file not found")
        #expect(TranscriberError.invalidCheckpoint("x").description == "not a valid muscriptor GGUF checkpoint")
        #expect(TranscriberError.unsupportedArchitecture("x").description
            == "checkpoint architecture is not supported")
        #expect(TranscriberError.unsupportedCheckpointVersion(found: 2).description
            == "checkpoint format version is not the one this build reads")
        #expect(TranscriberError.outOfMemory.description == "out of memory")
        #expect(TranscriberError.contextOverflow.description == "a chunk did not fit in the model context")
        #expect(TranscriberError.cancelled.description == "cancelled by the caller")
        #expect(TranscriberError.invalidArgument("x").description == "invalid transcribe options")
        #expect(TranscriberError.internalError("x").description == "internal error")
    }

    @Test func aMissingFileIsNotFound() {
        let error = #expect(throws: TranscriberError.self) {
            try Transcriber(url: URL(filePath: "/nonexistent/muscriptor-small-f16.gguf"))
        }

        guard case .fileNotFound = error else {
            Issue.record("expected .fileNotFound, got \(String(describing: error))")
            return
        }
    }

    @Test func aFileThatIsNotAGGUFIsAnInvalidCheckpoint() {
        // A JSON fixture that certainly exists and certainly is not a GGUF, so the failure
        // is the magic check and not a missing path.
        let error = #expect(throws: TranscriberError.self) {
            try Transcriber(url: Fixtures.url("vectors/tables.json"))
        }

        guard case .invalidCheckpoint = error else {
            Issue.record("expected .invalidCheckpoint, got \(String(describing: error))")
            return
        }
    }

    @Test func anotherCheckpointFormatVersionIsRejectedBeforeAnythingElseIsRead() throws {
        // Only the version key: `Hparams` reads it first precisely so that a layout this
        // build does not know fails on the version rather than on a key it happens to miss.
        var writer = GGUFWriter()
        writer.set("muscriptor.format_version", .int32(2))

        try withTemporaryFile(writer.build().data) { url in
            let error = #expect(throws: TranscriberError.self) { try Transcriber(url: url) }
            #expect(error == .unsupportedCheckpointVersion(found: 2))
        }
    }
}
