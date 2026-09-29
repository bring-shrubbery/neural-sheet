// Ported from the file-local helpers of muscriptor.cpp's cpp/src/transcriber.cpp --
// `requiredContext`, `melFramesPerChunk`, `uniqueInstruments` -- together with
// `Transcriber::Impl::_configure` and `_fillChunk`, and the try/catch of
// `Transcriber::load` that turns anything thrown into an `Error`.

import Foundation

extension Transcriber {
    /// Mel frames one chunk produces: centre padding yields one more than it covers.
    static func melFrames(hopLength: Int) -> Int {
        1 + segmentSamples / hopLength
    }

    /// KV positions to allocate: the prefix (mel frames, one dataset row, one row per
    /// selectable instrument), the initial token, and a chunk's worth of generation.
    ///
    /// Computed from the constants rather than written down so it cannot go stale against
    /// the front-end, and computed from the constants rather than from the checkpoint
    /// because the cache has to be sized before the checkpoint is read. It is 2538, and
    /// the geometry the numbers assume is what `Transcriber.init` then checks.
    static let requiredContextSize =
        melFrames(hopLength: sampleRate / Vocabulary.frameRate) + 1 + InstrumentGroups.maxSelectable + 1
            + maxTokensPerChunk

    /// Configures the model from `options`: the conditioning rows and the logit mask.
    ///
    /// Throws before touching the model on a bad selection, so a rejected call leaves it as
    /// the previous one configured it -- which is harmless, because the next call
    /// reconfigures it from scratch anyway.
    func configure(_ options: TranscribeOptions) throws {
        let instruments = Transcriber.unique(options.instruments)

        // Unreachable while `InstrumentGroup`'s cases and the group table agree: every case
        // is a named group and a raw value outside them cannot be constructed. It is kept
        // because it is the reference's guard and because the two *could* disagree -- a
        // nameless group would reach `conditioningRows` with no row of its own.
        for group in instruments where group.name.isEmpty {
            throw TranscriberError.invalidArgument("instrument group \(group.rawValue) has no name")
        }

        model.setInstrumentRows(InstrumentGroups.conditioningRows(instruments))

        // Guarded rather than called unconditionally: the reference forbids every program
        // and every drum for an empty selection, so passing one straight through would turn
        // "no filter" into "no instruments".
        if instruments.isEmpty {
            model.setForbiddenTokens([])
        } else {
            model.setForbiddenTokens(InstrumentGroups.forbiddenTokenIDs(instruments))
        }
    }

    /// The selection with duplicates removed and the caller's order kept.
    ///
    /// Order matters: it is the order of the conditioning rows, which are positions in the
    /// prefix, so sorting or hashing the selection would change the tokens. A `Set` is
    /// therefore not an option, and the linear scan is free at 35 groups.
    static func unique(_ groups: [InstrumentGroup]) -> [InstrumentGroup] {
        var unique: [InstrumentGroup] = []

        for group in groups where !unique.contains(group) {
            unique.append(group)
        }

        return unique
    }

    /// One chunk's samples into `chunkBuffer`, zero-padded to a full segment.
    ///
    /// The buffer is rewritten rather than reallocated, and the padding is part of the
    /// contract, not a convenience: the conditioner is handed a full window and the model
    /// sees the trailing zeros as audio. @see Transcriber.run
    func fillChunk(from samples: [Float], index: Int) {
        let start = index * Transcriber.segmentSamples
        let available = max(0, min(Transcriber.segmentSamples, samples.count - start))

        if available > 0 {
            chunkBuffer.replaceSubrange(0 ..< available, with: samples[start ..< start + available])
        }

        if available < Transcriber.segmentSamples {
            chunkBuffer.replaceSubrange(
                available ..< Transcriber.segmentSamples,
                with: repeatElement(0, count: Transcriber.segmentSamples - available))
        }
    }

    /// Runs `body`, turning anything it throws into a `TranscriberError`.
    ///
    /// The layers below only ever throw `TranscriberError`, so this is a backstop rather
    /// than a translation: it stands in for the C++'s `catch (const std::exception&)` and
    /// guarantees the public API's one error type even if something new starts throwing.
    /// `.outOfMemory` has no counterpart -- Swift traps on an allocation failure instead of
    /// throwing -- so it is left for a backend to report.
    static func mappingFailures<T>(_ body: () throws -> T) throws -> T {
        do {
            return try body()
        } catch let error as TranscriberError {
            throw error
        } catch {
            throw TranscriberError.internalError("\(error)")
        }
    }
}
