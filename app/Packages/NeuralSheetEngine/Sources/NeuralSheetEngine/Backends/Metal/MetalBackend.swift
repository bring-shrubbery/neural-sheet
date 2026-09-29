// Ported from `buildEvalGraph` in muscriptor.cpp's cpp/src/model.cpp, the branch where
// ggml's Metal backend owns the buffers: `Model::load`'s upload of every tensor into a
// backend buffer, and the graph allocator's activation arena. Here the upload is one
// `MTLBuffer` holding the GGUF's whole data section and the arena is the scratch buffers
// below, because our tensors have fixed shapes and there is no graph to plan.
//
// The forward pass itself is MetalBackend+Forward.swift; this file is the bring-up.

import Foundation
import Metal

/// The transformer stack on the GPU. @see TransformerBackend, CPUBackend
///
/// Every buffer is `storageModeShared`: on Apple silicon the GPU reads system memory at
/// full speed, so private storage would buy nothing, and shared storage is what lets
/// `reset` be a `memset`, the input be a `memcpy` and a failing layer be dumped from a test
/// and diffed against `CPUBackend`'s.
///
/// One call at a time; nothing here is thread-safe.
final class MetalBackend: TransformerBackend {
    let name = "Metal"
    let contextSize: Int

    private let device: MTLDevice

    /// Not private: MetalBackend+Forward.swift is another file, and `private` is file-scoped.
    let queue: MTLCommandQueue
    let kernels: MetalKernels

    let hparams: Hparams

    /// `1 / sqrt(headDim)`, computed once in `Float` as the C++ does.
    let attentionScale: Float

    /// The GGUF's data section, copied once. Tensor offsets are relative to that section,
    /// so a tensor is this buffer plus `TensorInfo.offset` and nothing has to be sliced out.
    let weightsBuffer: MTLBuffer

    /// K and V for every layer, `[nCtx][dim]` each, in one buffer -- 218 MB for the small
    /// checkpoint at nCtx = 2538, exactly what the C++ allocates for the same context.
    let cacheBuffer: MTLBuffer

    /// `[vocabSize]`, read back by the CPU after every pass.
    let logitsBuffer: MTLBuffer

    /// One block's weights and its slice of the cache, all as byte offsets: `qkv` and
    /// friends into `weightsBuffer`, `keys` and `values` into `cacheBuffer`.
    struct Layer {
        var attnNormW: Int
        var attnNormB: Int
        var ffnNormW: Int
        var ffnNormB: Int
        var qkv: Int
        var attnOut: Int
        var ffnUp: Int
        var ffnDown: Int
        var keys: Int
        var values: Int
    }

    let layers: [Layer]
    let outputNormW: Int
    let outputNormB: Int
    let outputHead: Int

    // The activations, grown to the window by `reserve` rather than sized for
    // `contextSize`: a scores buffer for a 2538-row window would be 300 MB for a window the
    // engine never feeds. @see MetalBackend+Forward
    let x: MetalScratch
    let normed: MetalScratch
    let qkv: MetalScratch
    let attended: MetalScratch
    let projected: MetalScratch
    let ffn: MetalScratch
    let scores: MetalScratch

    /// The hook `Model.load` calls. Nil means there is no GPU to run this on, which is not an
    /// error but the CPU backend's job: no Metal device at all, a device the kernels cannot
    /// dispatch on (`.unsupportedArchitecture`), or one whose memory the weights and the cache
    /// do not fit (`.outOfMemory`).
    ///
    /// Every other failure is rethrown. A shader that will not compile, a pipeline that will
    /// not build and a tensor whose shape contradicts the hyperparameters are a bug in this
    /// build or a broken checkpoint, and a silent fall back to the CPU would hide exactly the
    /// failures a test or a bug report needs to see -- the app would transcribe at a fraction
    /// of the speed with nothing saying why.
    static func make(
        file: GGUFFile, hparams: Hparams, weights: ModelWeights, contextSize: Int
    ) throws -> TransformerBackend? {
        guard let device = MTLCreateSystemDefaultDevice() else { return nil }

        do {
            return try MetalBackend(
                device: device, file: file, hparams: hparams, weights: weights, contextSize: contextSize)
        } catch TranscriberError.unsupportedArchitecture, TranscriberError.outOfMemory {
            return nil
        }
    }

    /// `.invalidCheckpoint` when a tensor is not the type or the extent the hyperparameters
    /// say it is -- the kernels index without bounds checks, so the shapes are established
    /// here or not at all -- `.outOfMemory` when a buffer does not fit on the device, and
    /// `.internalError` when the shader library or a pipeline will not build.
    init(device: MTLDevice, file: GGUFFile, hparams: Hparams, weights: ModelWeights, contextSize: Int) throws {
        guard contextSize > 0 else {
            throw TranscriberError.internalError("context size must be positive, not \(contextSize)")
        }

        // Non-uniform threadgroup dispatch, which every kernel over a 2D or 3D grid below
        // relies on to avoid a bounds check per thread. Apple silicon has had it since the
        // A11; the package is arm64-only, so this is a guard and not a fallback.
        guard device.supportsFamily(.apple4) else {
            throw TranscriberError.unsupportedArchitecture(
                "the Metal device '\(device.name)' does not support non-uniform threadgroups")
        }

        guard let queue = device.makeCommandQueue() else {
            throw TranscriberError.internalError("the Metal device would not make a command queue")
        }

        self.device = device
        self.queue = queue
        self.hparams = hparams
        self.contextSize = contextSize
        attentionScale = 1 / sqrt(Float(hparams.headDim))
        kernels = try MetalKernels(device: device, library: try MetalBackend.sharedLibrary(device: device))

        let dim = hparams.dim
        let nLayer = hparams.nLayer

        let section = file.dataSection

        guard let base = section.baseAddress, section.count > 0, section.count <= device.maxBufferLength,
            let uploaded = device.makeBuffer(bytes: base, length: section.count, options: .storageModeShared)
        else {
            throw TranscriberError.outOfMemory
        }

        weightsBuffer = uploaded

        let cacheBytes = nLayer * 2 * contextSize * dim * 4

        guard cacheBytes <= device.maxBufferLength,
            let caches = device.makeBuffer(length: cacheBytes, options: .storageModeShared)
        else {
            throw TranscriberError.outOfMemory
        }

        cacheBuffer = caches

        guard let logitRow = device.makeBuffer(length: hparams.vocabSize * 4, options: .storageModeShared) else {
            throw TranscriberError.outOfMemory
        }

        logitsBuffer = logitRow

        x = try MetalScratch(device: device)
        normed = try MetalScratch(device: device)
        qkv = try MetalScratch(device: device)
        attended = try MetalScratch(device: device)
        projected = try MetalScratch(device: device)
        ffn = try MetalScratch(device: device)
        scores = try MetalScratch(device: device)

        func floats(_ info: TensorInfo, _ count: Int) throws -> Int {
            try MetalBackend.offset(of: info, type: .f32, count: count)
        }

        func halves(_ info: TensorInfo, _ count: Int) throws -> Int {
            try MetalBackend.offset(of: info, type: .f16, count: count)
        }

        outputNormW = try floats(weights.outputNormW, dim)
        outputNormB = try floats(weights.outputNormB, dim)
        outputHead = try halves(weights.output, hparams.vocabSize * dim)

        layers = try (0 ..< nLayer).map { index in
            let layer = weights.layers[index]

            return Layer(
                attnNormW: try floats(layer.attnNormW, dim),
                attnNormB: try floats(layer.attnNormB, dim),
                ffnNormW: try floats(layer.ffnNormW, dim),
                ffnNormB: try floats(layer.ffnNormB, dim),
                qkv: try halves(layer.attnQKV, 3 * dim * dim),
                attnOut: try halves(layer.attnOut, dim * dim),
                ffnUp: try halves(layer.ffnUp, hparams.ffnDim * dim),
                ffnDown: try halves(layer.ffnDown, dim * hparams.ffnDim),
                keys: (index * 2) * contextSize * dim * 4,
                values: (index * 2 + 1) * contextSize * dim * 4)
        }

        // Metal does not promise a new buffer is zeroed, and `reset` is what the reference
        // does between chunks anyway.
        reset()
    }

    /// The reference zeroes the cache here too. Nothing reads past the filled rows, so this
    /// is not needed for correctness -- it is here so that an off-by-one in the causal bound
    /// shows up as an obviously wrong number rather than as a plausible one.
    ///
    /// Safe without a fence because `forward` waits for its command buffer: when this runs
    /// there is never GPU work in flight over the cache.
    func reset() {
        memset(cacheBuffer.contents(), 0, cacheBuffer.length)
    }

    /// The tensor's byte offset inside the data section, once its type and extent are the
    /// ones the hyperparameters imply.
    ///
    /// The offset has to be four-byte aligned because that is what Metal requires of a
    /// buffer binding; a GGUF's data section is aligned to at least 32 bytes and so is every
    /// tensor in it, so this rejects nothing a converter writes.
    private static func offset(of info: TensorInfo, type: TensorDataType, count: Int) throws -> Int {
        guard info.dataType == type, info.elementCount == count else {
            throw TranscriberError.invalidCheckpoint(
                "tensor '\(info.name)' is \(info.elementCount) values of \(info.dataType), "
                    + "expected \(count) \(type)")
        }

        guard info.offset % 4 == 0 else {
            throw TranscriberError.invalidCheckpoint(
                "tensor '\(info.name)' is at offset \(info.offset), which the GPU cannot bind")
        }

        return info.offset
    }

    // The shader library, compiled once per process. Compiling the source takes tens of
    // milliseconds and a `Transcriber` may be built per file, so the result is cached; it
    // is keyed by the device because a machine can have more than one and a library belongs
    // to the device that compiled it.
    private nonisolated(unsafe) static var cachedLibrary: (device: MTLDevice, library: MTLLibrary)?
    private static let libraryLock = NSLock()

    /// `.internalError` when the MSL does not compile, which is a bug in this build and
    /// never something about the machine.
    private static func sharedLibrary(device: MTLDevice) throws -> MTLLibrary {
        libraryLock.lock()
        defer { libraryLock.unlock() }

        if let cached = cachedLibrary, cached.device === device {
            return cached.library
        }

        do {
            // `options: nil` is Metal's default fast math, which is what ggml's own library is
            // built with. The kernels do rely on one thing it is allowed to break: `-INFINITY`
            // surviving `max` and `exp` in the masked softmax, which the Metal oracle dumps
            // confirm it does on this hardware. `MTLCompileOptions.mathMode` set to `.relaxed`
            // or `.safe` is the switch to reach for if a device ever disagrees.
            let library = try device.makeLibrary(source: MetalShaderSource.source, options: nil)
            cachedLibrary = (device, library)
            return library
        } catch {
            throw TranscriberError.internalError(
                "the Metal shader library would not compile: \(error.localizedDescription)")
        }
    }
}

/// One growable F32 `MTLBuffer`.
///
/// A class rather than a struct so that `forward` can grow it through a `let` property, as
/// `CPUBackend`'s `FloatScratch` is, and for the same reason.
final class MetalScratch {
    private let device: MTLDevice
    private(set) var buffer: MTLBuffer
    private var capacity = 0

    /// Starts at the smallest buffer Metal will make rather than at nothing, because a
    /// zero-length buffer is not a buffer; every user calls `reserve` before binding it.
    init(device: MTLDevice) throws {
        guard let initial = device.makeBuffer(length: 4, options: .storageModeShared) else {
            throw TranscriberError.outOfMemory
        }

        self.device = device
        buffer = initial
    }

    /// Grows to at least `count` floats, discarding what was there. Every buffer is written
    /// before it is read on each pass, so nothing is carried over: a grow is a fresh
    /// allocation, not a copy.
    func reserve(_ count: Int) throws {
        guard count > capacity else { return }

        let length = count * 4

        guard length <= device.maxBufferLength,
            let grown = device.makeBuffer(length: length, options: .storageModeShared)
        else {
            throw TranscriberError.outOfMemory
        }

        buffer = grown
        capacity = count
    }
}
