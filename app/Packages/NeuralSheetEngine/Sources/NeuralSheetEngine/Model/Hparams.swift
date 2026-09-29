// Ported from muscriptor.cpp's cpp/src/model.cpp (`Model::load`'s metadata reads and
// its geometry check) and the `Hparams` of cpp/include/muscriptor/model.hpp.

/// Everything about a checkpoint's shape that the rest of the engine needs.
///
/// Read once at load and never derived from a tensor's extents: a checkpoint whose
/// metadata and tensors disagree is a broken checkpoint, and the metadata is what the
/// converter validated.
struct Hparams: Equatable, Sendable {
    var dim: Int
    var nHead: Int
    var headDim: Int
    var nLayer: Int
    var ffnDim: Int
    var vocabSize: Int
    var initialTokenID: Int
    var logitMaskStart: Int
    var layerNormEps: Float
    var maxPeriod: Float
    var sampleRate: Int
    var nFFT: Int
    var hopLength: Int
    var frameRate: Int
    var nMels: Int
    var logEps: Float

    /// Bins in a one-sided spectrum, which is what the mel filterbank expects.
    var nFreq: Int { nFFT / 2 + 1 }

    /// The checkpoint layout this build reads. Every key below is part of the contract
    /// this number names, so it is checked before any of them.
    static let formatVersion = 1
}

extension Hparams {
    /// The metadata prefix the converter writes, `muscriptor.<suffix>`.
    private static func key(_ suffix: String) -> String { "muscriptor.\(suffix)" }

    init(file: GGUFFile) throws {
        // Before anything else is read, as in the C++: an older or newer layout may
        // spell a key the same way and mean something else by it.
        let versionKey = Hparams.key("format_version")
        let version = file.has(versionKey) ? Int(try file.int32(versionKey)) : 0

        guard version == Hparams.formatVersion else {
            throw TranscriberError.unsupportedCheckpointVersion(found: version)
        }

        func int(_ suffix: String) throws -> Int { Int(try file.int32(Hparams.key(suffix))) }
        func float(_ suffix: String) throws -> Float { try file.float32(Hparams.key(suffix)) }

        // In the reference's order, so a checkpoint missing several keys names the same
        // one the C++ would have named.
        dim = try int("embedding_length")
        nLayer = try int("block_count")
        nHead = try int("attention.head_count")
        headDim = try int("attention.head_dim")
        ffnDim = try int("feed_forward_length")
        vocabSize = try int("vocab_size")
        initialTokenID = try int("initial_token_id")
        logitMaskStart = try int("logit_mask_start")
        layerNormEps = try float("attention.layer_norm_epsilon")
        maxPeriod = try float("position_embedding.max_period")
        sampleRate = try int("audio.sample_rate")
        nFFT = try int("audio.n_fft")
        hopLength = try int("audio.hop_length")
        frameRate = try int("audio.frame_rate")
        nMels = try int("audio.n_mels")
        logEps = try float("audio.log_eps")

        guard headDim * nHead == dim else {
            throw TranscriberError.unsupportedArchitecture(
                "inconsistent head geometry: \(nHead) heads x \(headDim) != \(dim)")
        }
    }
}
