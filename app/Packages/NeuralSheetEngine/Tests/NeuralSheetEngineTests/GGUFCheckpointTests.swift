// What the reader makes of a real checkpoint. Nothing here downloads anything, so
// each test skips when `small` is not installed; the values are the ones the C++
// engine reported for the same file, and `hparams.json` is its own dump of them.

import Foundation
import Testing

@testable import NeuralSheetEngine

/// The small checkpoint's hyperparameters, as the C++ engine reads them.
private let smallHparams = Hparams(
    dim: 768, nHead: 12, headDim: 64, nLayer: 14, ffnDim: 3072, vocabSize: 1393, initialTokenID: 1393,
    logitMaskStart: 1393, layerNormEps: 1e-5, maxPeriod: 10000, sampleRate: 16000, nFFT: 2048, hopLength: 160,
    frameRate: 100, nMels: 512, logEps: 1e-6)

@Suite struct GGUFCheckpointTests {
    @Test func readsTheSmallCheckpointsHparams() throws {
        // Skips without weights: the checkpoints are not in the repository.
        guard let url = Checkpoints.url(for: .small) else { return }

        let file = try GGUFFile(url: url)
        #expect(file.tensorInfos.count == 122)
        #expect(file.tensors.count == 122)
        #expect(file.alignment == 32)

        let hparams = try Hparams(file: file)
        #expect(hparams.dim == smallHparams.dim)
        #expect(hparams.nHead == smallHparams.nHead)
        #expect(hparams.headDim == smallHparams.headDim)
        #expect(hparams.nLayer == smallHparams.nLayer)
        #expect(hparams.ffnDim == smallHparams.ffnDim)
        #expect(hparams.vocabSize == smallHparams.vocabSize)
        #expect(hparams.initialTokenID == smallHparams.initialTokenID)
        #expect(hparams.logitMaskStart == smallHparams.logitMaskStart)
        #expect(abs(hparams.layerNormEps - smallHparams.layerNormEps) < 1e-9)
        #expect(hparams.maxPeriod == smallHparams.maxPeriod)
        #expect(hparams.sampleRate == smallHparams.sampleRate)
        #expect(hparams.nFFT == smallHparams.nFFT)
        #expect(hparams.hopLength == smallHparams.hopLength)
        #expect(hparams.frameRate == smallHparams.frameRate)
        #expect(hparams.nMels == smallHparams.nMels)
        #expect(abs(hparams.logEps - smallHparams.logEps) < 1e-12)
        #expect(hparams.nFreq == 1025)
    }

    @Test func agreesWithTheReferencesOwnHparamsDump() throws {
        guard let url = Checkpoints.url(for: .small) else { return }

        // Skips without the oracle fixtures, which Task 3 of the plan lands.
        guard let dump = try? Fixtures.json("oracle/small-cpu/hparams.json") as? [String: Any] else { return }

        let hparams = try Hparams(file: GGUFFile(url: url))

        func int(_ key: String) throws -> Int {
            try #require(dump[key] as? Int, "hparams.json is missing \(key)")
        }

        func float(_ key: String) throws -> Float {
            try Float(#require(dump[key] as? Double, "hparams.json is missing \(key)"))
        }

        #expect(hparams.dim == (try int("dim")))
        #expect(hparams.nHead == (try int("n_head")))
        #expect(hparams.headDim == (try int("head_dim")))
        #expect(hparams.nLayer == (try int("n_layer")))
        #expect(hparams.ffnDim == (try int("ffn_dim")))
        #expect(hparams.vocabSize == (try int("vocab_size")))
        #expect(hparams.initialTokenID == (try int("initial_token_id")))
        #expect(hparams.logitMaskStart == (try int("logit_mask_start")))
        #expect(hparams.layerNormEps == (try float("layer_norm_eps")))
        #expect(hparams.maxPeriod == (try float("max_period")))
        #expect(hparams.sampleRate == (try int("sample_rate")))
        #expect(hparams.nFFT == (try int("n_fft")))
        #expect(hparams.hopLength == (try int("hop_length")))
        #expect(hparams.frameRate == (try int("frame_rate")))
        #expect(hparams.nMels == (try int("n_mels")))
        #expect(hparams.logEps == (try float("log_eps")))
    }

    @Test func loadsTheSmallCheckpointsWeights() throws {
        guard let url = Checkpoints.url(for: .small) else { return }

        let file = try GGUFFile(url: url)
        let hparams = try Hparams(file: file)
        let weights = try ModelWeights(file: file, hparams: hparams)

        // GGUF stores torch's (out, in) as ne = [in, out], so the vocabulary is the
        // outer extent. It is one longer than `vocab_size`: the initial token has a row.
        #expect(weights.tokenEmbd.shape == [768, 1394])
        #expect(weights.tokenEmbd.dataType == .f16)
        #expect(weights.output.shape == [768, 1393])
        #expect(weights.outputNormW.shape == [768])
        #expect(weights.outputNormW.dataType == .f32)

        // The filterbank is transposed on conversion, so it is [n_freq, n_mels].
        #expect(weights.melFB.shape == [1025, 512])
        #expect(weights.melFB.dataType == .f32)
        #expect(weights.stftWindow.shape == [2048])
        #expect(weights.projW.shape == [512, 768])
        #expect(weights.projB.shape == [768])

        #expect(weights.layers.count == 14)
        #expect(weights.layers[3].attnQKV.shape == [768, 2304])
        #expect(weights.layers[3].attnOut.shape == [768, 768])
        #expect(weights.layers[3].ffnUp.shape == [768, 3072])
        #expect(weights.layers[3].ffnDown.shape == [3072, 768])
    }

    @Test func readsTheSTFTWindowAsFloats() throws {
        guard let url = Checkpoints.url(for: .small) else { return }

        let file = try GGUFFile(url: url)
        let window = try file.tensor(named: "cond.stft_window")
        let values = try file.floats(of: window)

        // A periodic Hann window over 2048 samples: it starts at zero and peaks at 1
        // in the middle.
        #expect(values.count == 2048)
        #expect(values.allSatisfy { $0 >= 0 && $0 <= 1 })
        #expect(values[0] == 0)
        #expect(abs(values[1024] - 1) < 1e-3)
    }
}
