// Ported from `Model::encodeConditioning` in muscriptor.cpp's cpp/src/model.cpp, with
// vDSP and vForce in place of ggml: the conditioning path is two matrix products, a
// logarithm and a mask, so a compute graph and a backend buffer buy nothing here, and
// keeping it off the backend leaves the Metal path with only the transformer to run.

import Accelerate

/// The mel front-end: STFT magnitudes to the `[frames][dim]` embedding the transformer's
/// prefix begins with.
///
/// The filterbank, the window and the projection all come from the checkpoint. The stored
/// filterbank differs from MuScriptor's own `melscale_fbanks` by about 2e-4 relative, so
/// regenerating one would move every logit.
///
/// One call at a time; nothing here is mutated after `init`.
struct ConditioningFrontEnd {
    let hparams: Hparams
    let stft: STFT

    /// `cond.mel_fb.weight` transposed back, `[nFreq][nMels]` row-major.
    ///
    /// The converter already transposes the filterbank, so ggml's `ne` is
    /// `[nFreq, nMels]` and reading the bytes row-major gives `[nMels][nFreq]`. The
    /// contraction below runs over `nFreq`, and `vDSP_mmul` has no transpose flag, so the
    /// transpose is paid once at load rather than per chunk.
    private let melFBTransposed: [Float]

    /// `cond.proj.weight` transposed, `[nMels][dim]` row-major: stored `ne` is
    /// `[nMels, dim]`, so the bytes read row-major as `[dim][nMels]`. @see melFBTransposed
    private let projWTransposed: [Float]

    /// `cond.proj.bias`, `[dim]`.
    private let projB: [Float]

    /// `.internalError` when a conditioning tensor does not hold what the hyperparameters
    /// say it should, and whatever `STFT.init` throws for the window.
    ///
    /// The tensors are F32 in every checkpoint the converter writes; `floats(of:)` would
    /// widen an F16 one, so the counts are what is checked here — a tensor of the wrong
    /// extent is the failure that would otherwise surface as a plausible-looking
    /// embedding rather than as an error.
    init(file: GGUFFile, weights: ModelWeights, hparams: Hparams) throws {
        self.hparams = hparams
        stft = try STFT(
            nFFT: hparams.nFFT, hopLength: hparams.hopLength,
            window: try file.floats(of: weights.stftWindow))

        let melFB = try file.floats(of: weights.melFB)
        let projW = try file.floats(of: weights.projW)
        projB = try file.floats(of: weights.projB)

        try ConditioningFrontEnd.check(melFB.count, is: hparams.nMels * hparams.nFreq, "cond.mel_fb.weight")
        try ConditioningFrontEnd.check(projW.count, is: hparams.dim * hparams.nMels, "cond.proj.weight")
        try ConditioningFrontEnd.check(projB.count, is: hparams.dim, "cond.proj.bias")

        melFBTransposed = ConditioningFrontEnd.transposed(melFB, rows: hparams.nMels, columns: hparams.nFreq)
        projWTransposed = ConditioningFrontEnd.transposed(projW, rows: hparams.dim, columns: hparams.nMels)
    }

    private static func check(_ count: Int, is expected: Int, _ name: String) throws {
        guard count == expected else {
            throw TranscriberError.internalError("\(name) holds \(count) values, expected \(expected)")
        }
    }

    /// `[rows][columns]` row-major to `[columns][rows]`. `vDSP_mtrans`'s M and N are the
    /// *output's* extents, which is the opposite of how the input is named here.
    private static func transposed(_ values: [Float], rows: Int, columns: Int) -> [Float] {
        var out = [Float](repeating: 0, count: values.count)
        vDSP_mtrans(values, 1, &out, 1, vDSP_Length(columns), vDSP_Length(rows))
        return out
    }

    /// The whole front-end for one chunk of audio: STFT, then `encode`.
    func encodeAudio(_ samples: [Float]) throws -> [Float] {
        let spectrum = try stft.magnitudes(samples)
        return try encode(
            spectrum: spectrum, frameCount: stft.frameCount(sampleCount: samples.count),
            sampleCount: samples.count)
    }

    /// `mel = fb · mag`, `logmel = log(mel + logEps)`, `proj = W · logmel + b`, then the
    /// frames past the end of the audio zeroed. Returns `[frameCount][dim]` row-major.
    ///
    /// `sampleCount` is the length of the waveform and not a frame count on purpose: the
    /// reference derives the mask from it, and a centre-padded STFT always yields one
    /// frame more than `sampleCount / hopLength`, so the last frame is always masked away.
    ///
    /// `.internalError` when `spectrum` is not `frameCount * nFreq` long.
    func encode(spectrum: [Float], frameCount: Int, sampleCount: Int) throws -> [Float] {
        let bins = hparams.nFreq
        let mels = hparams.nMels
        let dim = hparams.dim

        guard frameCount >= 0, spectrum.count == frameCount * bins else {
            throw TranscriberError.internalError(
                "spectrum has \(spectrum.count) values, expected \(frameCount * bins) "
                    + "(\(frameCount) frames x \(bins))")
        }

        guard frameCount > 0 else { return [] }

        var mel = [Float](repeating: 0, count: frameCount * mels)
        vDSP_mmul(
            spectrum, 1, melFBTransposed, 1, &mel, 1,
            vDSP_Length(frameCount), vDSP_Length(mels), vDSP_Length(bins))

        // The epsilon keeps the logarithm of an empty band finite; it is the checkpoint's,
        // not a guard of our own, so silent bands land where the reference puts them.
        var eps = hparams.logEps

        mel.withUnsafeMutableBufferPointer { values in
            vDSP_vsadd(values.baseAddress!, 1, &eps, values.baseAddress!, 1, vDSP_Length(values.count))
        }

        var logmel = [Float](repeating: 0, count: mel.count)
        var elements = Int32(mel.count)
        vvlogf(&logmel, mel, &elements)

        var embedding = [Float](repeating: 0, count: frameCount * dim)
        vDSP_mmul(
            logmel, 1, projWTransposed, 1, &embedding, 1,
            vDSP_Length(frameCount), vDSP_Length(dim), vDSP_Length(mels))

        let valid = min(max(sampleCount / stft.hopLength, 0), frameCount)

        embedding.withUnsafeMutableBufferPointer { destination in
            projB.withUnsafeBufferPointer { bias in
                for frame in 0 ..< valid {
                    let row = destination.baseAddress! + frame * dim
                    vDSP_vadd(row, 1, bias.baseAddress!, 1, row, 1, vDSP_Length(dim))
                }
            }

            // The mask is a multiply by zero in the reference, which wipes the bias too, so
            // the rows past the audio never get one and the projection written into them
            // above is cleared here rather than skipped: `vDSP_mmul` fills every row.
            if valid < frameCount {
                (destination.baseAddress! + valid * dim).update(
                    repeating: 0, count: (frameCount - valid) * dim)
            }
        }

        return embedding
    }
}
