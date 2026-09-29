// The reader is checked against files this test writes, so it can be shown to
// read every value type, to report the offsets the spec dictates, and to reject
// a file that is not a GGUF or has been cut short. A real checkpoint exercises
// none of that: it has no int8 keys and it is never truncated.

import Foundation
import Testing

@testable import NeuralSheetEngine

/// Every value type the spec defines, including an array, so one pass over the
/// metadata covers the whole switch.
private let sampleMetadata: [(key: String, value: GGUFValue)] = [
    ("general.alignment", .uint32(32)),
    ("general.architecture", .string("muscriptor")),
    ("t.uint8", .uint8(200)),
    ("t.int8", .int8(-100)),
    ("t.uint16", .uint16(60000)),
    ("t.int16", .int16(-30000)),
    ("t.uint32", .uint32(4_000_000_000)),
    ("t.int32", .int32(-2_000_000_000)),
    ("t.float32", .float32(0.5)),
    ("t.bool.true", .bool(true)),
    ("t.bool.false", .bool(false)),
    ("t.uint64", .uint64(18_000_000_000_000_000_000)),
    ("t.int64", .int64(-9_000_000_000_000_000_000)),
    ("t.float64", .float64(-1.25)),
    ("t.strings", .array([.string("gguf"), .string("ggml"), .string("音楽")])),
    ("t.int32s", .array([.int32(1), .int32(-2), .int32(3)])),
]

/// Exactly representable in Float16, so a round trip through the F16 tensor is an
/// equality check and not a tolerance one.
private let f16Values: [Float] = [0, 0.5, -1.25, 1024, -2048, 3, -0.125, 65504]

private let f32Values: [Float] = (0 ..< 12).map { Float($0) * 0.25 - 1 }

private func sampleWriter() -> GGUFWriter {
    var writer = GGUFWriter()

    for entry in sampleMetadata {
        writer.set(entry.key, entry.value)
    }

    writer.addTensor("weights", shape: [4, 3], dataType: .f32, values: f32Values)
    writer.addTensor("window", shape: [8], dataType: .f16, values: f16Values)
    return writer
}

/// The seventeen metadata keys `Hparams` reads, so a test can hand it a file that is
/// complete except for the one thing the test is about.
private func hparamsWriter() -> GGUFWriter {
    var writer = GGUFWriter()
    writer.set("muscriptor.format_version", .int32(1))
    writer.set("muscriptor.embedding_length", .int32(768))
    writer.set("muscriptor.block_count", .int32(14))
    writer.set("muscriptor.attention.head_count", .int32(12))
    writer.set("muscriptor.attention.head_dim", .int32(64))
    writer.set("muscriptor.feed_forward_length", .int32(3072))
    writer.set("muscriptor.vocab_size", .int32(1393))
    writer.set("muscriptor.initial_token_id", .int32(1393))
    writer.set("muscriptor.logit_mask_start", .int32(1393))
    writer.set("muscriptor.attention.layer_norm_epsilon", .float32(1e-5))
    writer.set("muscriptor.position_embedding.max_period", .float32(10000))
    writer.set("muscriptor.audio.sample_rate", .int32(16000))
    writer.set("muscriptor.audio.n_fft", .int32(2048))
    writer.set("muscriptor.audio.hop_length", .int32(160))
    writer.set("muscriptor.audio.frame_rate", .int32(100))
    writer.set("muscriptor.audio.n_mels", .int32(512))
    writer.set("muscriptor.audio.log_eps", .float32(1e-6))
    return writer
}

private func isInvalidCheckpoint(_ error: TranscriberError?) -> Bool {
    if case .invalidCheckpoint = error { return true }
    return false
}

private func isFileNotFound(_ error: TranscriberError?) -> Bool {
    if case .fileNotFound = error { return true }
    return false
}

private func isUnsupportedArchitecture(_ error: TranscriberError?) -> Bool {
    if case .unsupportedArchitecture = error { return true }
    return false
}

@Suite struct GGUFFileTests {
    @Test func readsEveryMetadataType() throws {
        try withTemporaryFile(sampleWriter().build().data) { url in
            let file = try GGUFFile(url: url)
            #expect(file.metadata.count == sampleMetadata.count)

            for entry in sampleMetadata {
                #expect(file.metadata[entry.key] == entry.value, "\(entry.key)")
                #expect(file.has(entry.key))
            }

            #expect(!file.has("t.absent"))
        }
    }

    @Test func readsTheTensorTableInFileOrder() throws {
        let blob = sampleWriter().build()

        try withTemporaryFile(blob.data) { url in
            let file = try GGUFFile(url: url)
            #expect(file.tensorInfos.map(\.name) == ["weights", "window"])
            #expect(file.tensors.count == 2)
            #expect(file.alignment == 32)
            #expect(file.dataOffset == blob.dataStart)

            let weights = try file.tensor(named: "weights")
            #expect(weights.shape == [4, 3])
            #expect(weights.dataType == .f32)
            #expect(weights.elementCount == 12)
            #expect(weights.byteCount == 48)
            #expect(weights.offset == 0)

            let window = try file.tensor(named: "window")
            #expect(window.shape == [8])
            #expect(window.dataType == .f16)
            #expect(window.elementCount == 8)
            #expect(window.byteCount == 16)
            // The writer pads each payload to the alignment, as GGUF requires.
            #expect(window.offset == 64)
        }
    }

    @Test func readsTensorBytesAndFloats() throws {
        try withTemporaryFile(sampleWriter().build().data) { url in
            let file = try GGUFFile(url: url)

            let weights = try file.tensor(named: "weights")
            #expect(Array(file.bytes(of: weights)) == GGUFWriter.encode(f32Values, as: .f32))
            let readF32 = try file.floats(of: weights)
            #expect(readF32 == f32Values)

            let window = try file.tensor(named: "window")
            #expect(Array(file.bytes(of: window)) == GGUFWriter.encode(f16Values, as: .f16))
            let readF16 = try file.floats(of: window)
            #expect(readF16 == f16Values)

            // The data section covers both payloads and their padding: 48 bytes rounded
            // up to 64, then 16 rounded up to 32.
            #expect(file.dataSection.count == 96)
        }
    }

    @Test func rejectsAMissingOrMistypedKey() throws {
        try withTemporaryFile(sampleWriter().build().data) { url in
            let file = try GGUFFile(url: url)
            let int = try file.int32("t.int32")
            #expect(int == -2_000_000_000)
            let float = try file.float32("t.float32")
            #expect(float == 0.5)

            let missing = #expect(throws: TranscriberError.self) { try file.int32("missing") }
            #expect(isInvalidCheckpoint(missing))

            let mistypedInt = #expect(throws: TranscriberError.self) { try file.int32("t.float32") }
            #expect(isInvalidCheckpoint(mistypedInt))

            let mistypedFloat = #expect(throws: TranscriberError.self) { try file.float32("t.int32") }
            #expect(isInvalidCheckpoint(mistypedFloat))

            let absentTensor = #expect(throws: TranscriberError.self) { try file.tensor(named: "absent") }
            #expect(isInvalidCheckpoint(absentTensor))
        }
    }

    @Test func rejectsAFileThatIsNotAGGUF() throws {
        try withTemporaryFile(Data("hello".utf8)) { url in
            let error = #expect(throws: TranscriberError.self) { try GGUFFile(url: url) }
            #expect(isInvalidCheckpoint(error))
        }
    }

    @Test func rejectsAnUnsupportedVersion() throws {
        var writer = sampleWriter()
        writer.version = 1

        try withTemporaryFile(writer.build().data) { url in
            let error = #expect(throws: TranscriberError.self) { try GGUFFile(url: url) }
            #expect(isInvalidCheckpoint(error))
        }
    }

    @Test func reportsAMissingPathAsSuch() {
        let url = FileManager.default.temporaryDirectory.appending(path: "NeuralSheetEngine-absent-\(UUID()).gguf")
        let error = #expect(throws: TranscriberError.self) { try GGUFFile(url: url) }
        #expect(isFileNotFound(error))
    }

    @Test func rejectsATruncatedFile() throws {
        let blob = sampleWriter().build()

        // Cut inside the tensor info table: the header and the metadata still parse,
        // so only a bounds check on every read catches this.
        try withTemporaryFile(blob.data.prefix(blob.tensorInfoEnd - 4)) { url in
            let error = #expect(throws: TranscriberError.self) { try GGUFFile(url: url) }
            #expect(isInvalidCheckpoint(error))
        }

        // Cut inside the data section, which the tensor table still claims in full.
        try withTemporaryFile(blob.data.prefix(blob.dataStart + 8)) { url in
            let error = #expect(throws: TranscriberError.self) { try GGUFFile(url: url) }
            #expect(isInvalidCheckpoint(error))
        }
    }

    @Test func rejectsATensorWhoseByteCountOverflows() throws {
        var writer = sampleWriter()

        // An extent that fits `Int` on its own but not once it is multiplied by the
        // element size: the byte count has to be checked where the shape is read, or
        // computing it later is an arithmetic trap the caller cannot catch.
        writer.addTensor("huge", shape: [1 << 62, 1], dataType: .f32, values: [])

        try withTemporaryFile(writer.build().data) { url in
            let error = #expect(throws: TranscriberError.self) { try GGUFFile(url: url) }
            #expect(isInvalidCheckpoint(error))
        }
    }

    @Test func rejectsAnotherCheckpointFormatVersion() throws {
        var writer = hparamsWriter()
        writer.set("muscriptor.format_version", .int32(2))

        try withTemporaryFile(writer.build().data) { url in
            let file = try GGUFFile(url: url)
            let error = #expect(throws: TranscriberError.self) { try Hparams(file: file) }
            #expect(error == .unsupportedCheckpointVersion(found: 2))
        }
    }

    @Test func treatsAMissingFormatVersionAsZero() throws {
        var writer = hparamsWriter()
        writer.remove("muscriptor.format_version")

        try withTemporaryFile(writer.build().data) { url in
            let file = try GGUFFile(url: url)
            let error = #expect(throws: TranscriberError.self) { try Hparams(file: file) }
            #expect(error == .unsupportedCheckpointVersion(found: 0))
        }
    }

    @Test func rejectsInconsistentHeadGeometry() throws {
        var writer = hparamsWriter()
        writer.set("muscriptor.attention.head_dim", .int32(60))

        try withTemporaryFile(writer.build().data) { url in
            let file = try GGUFFile(url: url)
            let error = #expect(throws: TranscriberError.self) { try Hparams(file: file) }
            #expect(isUnsupportedArchitecture(error))
        }
    }

    @Test func rejectsANonPositiveExtent() throws {
        var writer = hparamsWriter()

        // A negative dimension passes the version check and the head geometry would not even
        // be reached: every buffer in the engine is sized from this number, so it has to be
        // rejected where it is read.
        writer.set("muscriptor.embedding_length", .int32(-768))

        try withTemporaryFile(writer.build().data) { url in
            let file = try GGUFFile(url: url)
            let error = #expect(throws: TranscriberError.self) { try Hparams(file: file) }
            #expect(isInvalidCheckpoint(error))

            // The key is named, because a checkpoint with a bad extent is usually a converter
            // bug and the message is what points at it.
            if case .invalidCheckpoint(let message) = error {
                #expect(message.contains("muscriptor.embedding_length"), "\(message)")
            }
        }
    }

    @Test func rejectsDeeplyNestedMetadataArrays() throws {
        var writer = sampleWriter()

        // Sixteen levels, which the reader used to follow one stack frame at a time. Nothing
        // ggml writes nests at all, so the depth limit is what keeps a hand-built file from
        // recursing the reader off the stack instead of coming back as an error.
        var nested = GGUFValue.int32(7)

        for _ in 0 ..< 16 {
            nested = .array([nested])
        }

        writer.set("t.nested", nested)

        try withTemporaryFile(writer.build().data) { url in
            let error = #expect(throws: TranscriberError.self) { try GGUFFile(url: url) }
            #expect(error == .invalidCheckpoint("metadata nests arrays too deeply"))
        }
    }

    @Test func readsAWholeHparamsBlock() throws {
        try withTemporaryFile(hparamsWriter().build().data) { url in
            let hparams = try Hparams(file: GGUFFile(url: url))
            #expect(hparams.dim == 768)
            #expect(hparams.nHead == 12)
            #expect(hparams.headDim == 64)
            #expect(hparams.nLayer == 14)
            #expect(hparams.ffnDim == 3072)
            #expect(hparams.vocabSize == 1393)
            #expect(hparams.initialTokenID == 1393)
            #expect(hparams.logitMaskStart == 1393)
            #expect(abs(hparams.layerNormEps - 1e-5) < 1e-9)
            #expect(hparams.maxPeriod == 10000)
            #expect(hparams.sampleRate == 16000)
            #expect(hparams.nFFT == 2048)
            #expect(hparams.hopLength == 160)
            #expect(hparams.frameRate == 100)
            #expect(hparams.nMels == 512)
            #expect(abs(hparams.logEps - 1e-6) < 1e-12)
            #expect(hparams.nFreq == 1025)
        }
    }

    @Test func reportsAMissingHparamsKey() throws {
        var writer = hparamsWriter()
        writer.remove("muscriptor.audio.n_mels")

        try withTemporaryFile(writer.build().data) { url in
            let file = try GGUFFile(url: url)
            let error = #expect(throws: TranscriberError.self) { try Hparams(file: file) }
            #expect(isInvalidCheckpoint(error))
        }
    }
}
