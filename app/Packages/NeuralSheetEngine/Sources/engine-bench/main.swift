// The Swift counterpart of muscriptor.cpp's cpp/bench/bench.cpp: the whole-signal number
// a caller feels (its `--transcribe` mode) and the per-phase breakdown an optimisation is
// tuned against (its default mode), in one run over the engine's own audio fixture.
//
// This is the only file in the package allowed to print.

import Foundation
import NeuralSheetEngine

let usage = "usage: engine-bench <checkpoint.gguf> [cpu|gpu] [audio.wav]"

/// Decode steps the per-phase breakdown times, enough for the mean to settle and short
/// enough that the KV cache stays the length a real chunk's first tokens see.
let decodeSteps = 200

func fail(_ message: String, code: Int32 = 1) -> Never {
    FileHandle.standardError.write(Data("engine-bench: \(message)\n".utf8))
    exit(code)
}

/// A label and a value in two columns, so a run's output diffs against another's.
func row(_ label: String, _ value: String) {
    print(label.padding(toLength: 14, withPad: " ", startingAt: 0) + value)
}

/// Reads the one kind of file this benchmark consumes: 16 kHz mono float32 WAV. Anything
/// else is an error rather than a conversion -- a silently resampled fixture would make
/// every number below meaningless.
func readFloatWAV(_ url: URL) -> [Float] {
    guard let data = try? Data(contentsOf: url) else {
        fail("cannot read \(url.path(percentEncoded: false))")
    }

    return data.withUnsafeBytes { raw -> [Float] in
        func fourCC(at offset: Int) -> String {
            String(decoding: (0 ..< 4).map { raw[offset + $0] }, as: UTF8.self)
        }

        func integer(at offset: Int, bytes: Int) -> Int {
            (0 ..< bytes).reduce(0) { $0 | Int(raw[offset + $1]) << (8 * $1) }
        }

        guard raw.count >= 12, fourCC(at: 0) == "RIFF", fourCC(at: 8) == "WAVE" else {
            fail("\(url.lastPathComponent) is not a RIFF/WAVE file")
        }

        var format = 0
        var channels = 0
        var rate = 0
        var bits = 0
        var samples: [Float] = []
        var offset = 12

        // Each chunk is a four-byte id, a little-endian size and a payload padded to an
        // even length; the padding is not counted in the size.
        while offset + 8 <= raw.count {
            let chunk = fourCC(at: offset)
            let length = integer(at: offset + 4, bytes: 4)
            let body = offset + 8

            if chunk == "fmt ", length >= 16, body + 16 <= raw.count {
                format = integer(at: body, bytes: 2)
                channels = integer(at: body + 2, bytes: 2)
                rate = integer(at: body + 4, bytes: 4)
                bits = integer(at: body + 14, bytes: 2)
            } else if chunk == "data" {
                let count = min(length, raw.count - body) / 4
                samples = (0 ..< count).map { index -> Float in
                    let bits = raw.loadUnaligned(fromByteOffset: body + index * 4, as: UInt32.self)
                    return Float(bitPattern: UInt32(littleEndian: bits))
                }
            }

            offset = body + length + length % 2
        }

        guard format == 3, channels == 1, bits == 32, rate == Transcriber.sampleRate else {
            fail("expected 16 kHz mono float32, got format \(format), \(channels) ch, \(rate) Hz, \(bits) bit")
        }

        return samples
    }
}

/// Percentile `quantile` of an already-sorted array, indexed as the C++ benchmark's is so
/// the two print the same statistic.
func percentile(_ sorted: [Double], _ quantile: Double) -> Double {
    guard !sorted.isEmpty else { return 0 }
    return sorted[min(sorted.count - 1, Int(quantile * Double(sorted.count)))]
}

let arguments = Array(CommandLine.arguments.dropFirst())

guard (1 ... 3).contains(arguments.count) else {
    fail(usage, code: 2)
}

let checkpoint = URL(filePath: arguments[0])
let device = arguments.count > 1 ? arguments[1] : "gpu"

guard device == "cpu" || device == "gpu" else {
    fail("the device must be cpu or gpu, not '\(device)'\n\(usage)", code: 2)
}

// Resolved from this source file rather than from the working directory, so the default
// run works from anywhere: `#filePath` is Sources/engine-bench/main.swift.
let packageRoot = URL(filePath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

let audioURL = arguments.count > 2
    ? URL(filePath: arguments[2])
    : packageRoot.appending(path: "Tests/NeuralSheetEngineTests/Fixtures/audio/fixture_3chunks_16k.wav")

let signal = readFloatWAV(audioURL)
let clock = ContinuousClock()

do {
    let transcriber = try Transcriber(url: checkpoint, options: LoadOptions(useGPU: device == "gpu"))

    let began = clock.now
    let notes = try transcriber.transcribe(samples: signal)
    let wall = Transcriber.milliseconds(clock.now - began) / 1000

    let audioSeconds = Double(signal.count) / Double(Transcriber.sampleRate)

    row("weights", checkpoint.lastPathComponent)
    row("backend", transcriber.backendName)
    row("audio", String(format: "%8.2f s   (%d chunks)", audioSeconds,
                        Transcriber.chunkCount(sampleCount: signal.count)))
    row("wall", String(format: "%8.2f s", wall))
    row("real-time", String(format: "%8.2f x", wall > 0 ? audioSeconds / wall : 0))
    row("notes", String(format: "%8d", notes.count))

    // The breakdown, on chunk 0 only and through the model directly: what the kernels cost,
    // separated from the chunking and the note assembly above them.
    let phases = try transcriber.measurePhases(samples: signal, chunk: 0, steps: decodeSteps)
    let decode = phases.decodeMilliseconds
    let mean = decode.isEmpty ? 0 : decode.reduce(0, +) / Double(decode.count)

    row("conditioning", String(format: "%8.1f ms", phases.conditioningMilliseconds))
    row("prefill", String(format: "%8.1f ms", phases.prefillMilliseconds))
    row("decode", String(format: "%8.2f ms/step mean   p50 %.2f ms   over %d steps",
                         mean, percentile(decode.sorted(), 0.50), decode.count))
    row("decode", String(format: "%8.1f tok/s", mean > 0 ? 1000 / mean : 0))
} catch let error as TranscriberError {
    fail("\(error.description): \(error)")
} catch {
    fail("\(error)")
}
