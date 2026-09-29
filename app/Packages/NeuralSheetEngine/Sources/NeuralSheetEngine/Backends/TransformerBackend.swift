// The seam the C++ does not have. muscriptor.cpp's cpp/src/model.cpp builds one ggml
// graph and hands it to whichever ggml backend was initialised, so its device choice is
// invisible inside `buildEvalGraph`. With our own kernels the graph is the Swift code, so
// the device choice has to be a type: this protocol is the whole of it.
//
// The split is drawn at the layer-0 activations rather than at the token ids because
// everything above it -- the prefix assembly, the position rows, the logit mask and the
// greedy step -- is integer and elementwise work that runs on the CPU either way, and
// duplicating it per backend is how the two would drift apart.

/// One checkpoint's transformer stack, with its own KV cache, on one device.
///
/// A backend owns the cache, so it is stateful: a caller feeds it consecutive windows of
/// one sequence and tells it how much of that sequence is already cached. One call at a
/// time; nothing here is thread-safe.
protocol TransformerBackend: AnyObject {
    /// `"CPU"` or `"Metal"`, which is what `Transcriber.backendName` reports.
    var name: String { get }

    /// Rows of KV cache, and so the longest sequence a pass may end at.
    var contextSize: Int { get }

    /// Forgets the cached sequence: `nPast` starts again at zero.
    func reset()

    /// Runs the stack over `nNew` new positions and returns the last one's raw logits.
    ///
    /// `input` is the layer-0 activations, `[nNew][dim]` row-major: the embeddings with
    /// the position rows already added. The pass appends this window's keys and values at
    /// cache rows `nPast ..< nPast + nNew` and attends over every row up to and including
    /// each query's own position, so a caller that feeds the same window twice must
    /// `reset()` in between.
    ///
    /// Only the last row reaches the LM head, because only the last position is ever
    /// sampled. The logits are `[vocabSize]` and unmasked: the vocabulary's reserved tail
    /// and the caller's forbidden ids are `Model`'s business, not a device's.
    ///
    /// Throws `.contextOverflow` when `nPast + nNew` exceeds `contextSize`, and
    /// `.internalError` when `input` is not `nNew · dim` values.
    func forward(input: [Float], nNew: Int, nPast: Int) throws -> [Float]
}
