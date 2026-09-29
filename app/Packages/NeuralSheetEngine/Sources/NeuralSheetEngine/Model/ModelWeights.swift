// Ported from muscriptor.cpp's cpp/src/model.cpp (`Model::load`'s weight lookups) and
// the `Weights` of cpp/include/muscriptor/model.hpp. The names are the tensor map of
// muscriptor.cpp's docs/MODEL.md.

/// One transformer block's tensors.
///
/// `attnQKV` packs q, k and v with q outermost, which is already ggml's layout, so the
/// three are slices of it and never a copy.
struct LayerWeights: Sendable {
    var attnNormW: TensorInfo
    var attnNormB: TensorInfo
    var attnQKV: TensorInfo
    var attnOut: TensorInfo
    var ffnNormW: TensorInfo
    var ffnNormB: TensorInfo
    var ffnUp: TensorInfo
    var ffnDown: TensorInfo
}

/// Where every weight of a loaded checkpoint lives.
///
/// These are offsets into the mapped file, not copies, so a `ModelWeights` is only
/// meaningful while the `GGUFFile` it was read from is alive.
struct ModelWeights: Sendable {
    var tokenEmbd: TensorInfo
    var output: TensorInfo
    var outputNormW: TensorInfo
    var outputNormB: TensorInfo
    var melFB: TensorInfo
    var stftWindow: TensorInfo
    var projW: TensorInfo
    var projB: TensorInfo
    var instrumentGroup: TensorInfo
    var datasetName: TensorInfo
    var layers: [LayerWeights]

    /// Every tensor the architecture needs, or `.invalidCheckpoint` naming the first one
    /// that is absent: a model that loaded with a hole in it would fail later, in a
    /// kernel, with nothing to tell the user.
    init(file: GGUFFile, hparams: Hparams) throws {
        tokenEmbd = try file.tensor(named: "token_embd.weight")
        output = try file.tensor(named: "output.weight")
        outputNormW = try file.tensor(named: "output_norm.weight")
        outputNormB = try file.tensor(named: "output_norm.bias")
        melFB = try file.tensor(named: "cond.mel_fb.weight")
        stftWindow = try file.tensor(named: "cond.stft_window")
        projW = try file.tensor(named: "cond.proj.weight")
        projB = try file.tensor(named: "cond.proj.bias")
        instrumentGroup = try file.tensor(named: "cond.instrument_group.weight")
        datasetName = try file.tensor(named: "cond.dataset_name.weight")

        layers = try (0 ..< hparams.nLayer).map { index in
            func part(_ name: String) throws -> TensorInfo {
                try file.tensor(named: "blk.\(index).\(name)")
            }

            return LayerWeights(
                attnNormW: try part("attn_norm.weight"),
                attnNormB: try part("attn_norm.bias"),
                attnQKV: try part("attn_qkv.weight"),
                attnOut: try part("attn_out.weight"),
                ffnNormW: try part("ffn_norm.weight"),
                ffnNormB: try part("ffn_norm.bias"),
                ffnUp: try part("ffn_up.weight"),
                ffnDown: try part("ffn_down.weight"))
        }
    }
}
