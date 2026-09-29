// Access to the oracle fixtures copied verbatim from muscriptor.cpp's
// `testdata/`. They are the behavioural contract for the port, so they are read
// rather than regenerated: a test that disagrees with a fixture is a bug in the
// Swift, never a reason to edit the JSON.

import Foundation

@testable import NeuralSheetEngine

enum FixtureError: Error, CustomStringConvertible {
    case missing(String)
    case malformed(String)

    var description: String {
        switch self {
        case .missing(let path): return "fixture not found: \(path)"
        case .malformed(let path): return "fixture is not in the expected format: \(path)"
        }
    }
}

enum Fixtures {
    /// The URL of a file under `Tests/NeuralSheetEngineTests/Fixtures`, which SwiftPM
    /// copies into the test bundle's resources with its directory structure intact.
    static func url(_ relativePath: String) -> URL {
        let root = Bundle.module.resourceURL ?? Bundle.module.bundleURL
        return root.appending(path: "Fixtures").appending(path: relativePath)
    }

    /// A fixture parsed by `JSONSerialization`, which keeps the numbers as `NSNumber`
    /// so a test can ask for `Int` or `Double` as the reference's own type dictates.
    static func json(_ relativePath: String) throws -> Any {
        let url = url(relativePath)

        guard let data = try? Data(contentsOf: url) else {
            throw FixtureError.missing(relativePath)
        }

        return try JSONSerialization.jsonObject(with: data)
    }

    /// A raw `.f32` dump: little-endian 32-bit floats, nothing else in the file.
    static func floats(_ relativePath: String) throws -> [Float] {
        guard let data = try? Data(contentsOf: url(relativePath)) else {
            throw FixtureError.missing(relativePath)
        }

        guard data.count % 4 == 0 else {
            throw FixtureError.malformed(relativePath)
        }

        return data.withUnsafeBytes { raw in
            (0 ..< data.count / 4).map { index in
                Float(bitPattern: UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: index * 4, as: UInt32.self)))
            }
        }
    }

    /// The 16 kHz mono float32 audio fixture the reference dumps its oracle from.
    static func fixtureAudio() throws -> [Float] {
        try wavFloats("audio/fixture_3chunks_16k.wav")
    }

    /// One chunk of a signal, zero-padded to the segment length the way `Transcriber` pads
    /// the last one, for the tests that drive `Model` directly instead of going through the
    /// chunk loop. The audio fixture's three chunks are full, so only a fourth would pad.
    static func chunk(_ audio: [Float], _ index: Int) -> [Float] {
        var samples = [Float](repeating: 0, count: Transcriber.segmentSamples)
        let first = index * Transcriber.segmentSamples
        let available = min(Transcriber.segmentSamples, audio.count - first)

        if available > 0 {
            samples.replaceSubrange(0 ..< available, with: audio[first ..< (first + available)])
        }

        return samples
    }

    /// Reads a WAV whose `fmt ` format is 3 (IEEE float) by walking the RIFF chunks:
    /// past the 12-byte header, each chunk is a four-byte id, a little-endian size and
    /// a payload padded to an even length. Only the `data` chunk is needed, and its
    /// bytes are already the samples the engine wants.
    private static func wavFloats(_ relativePath: String) throws -> [Float] {
        guard let data = try? Data(contentsOf: url(relativePath)) else {
            throw FixtureError.missing(relativePath)
        }

        return try data.withUnsafeBytes { raw -> [Float] in
            func fourCC(at offset: Int) -> String {
                String(decoding: (0 ..< 4).map { raw[offset + $0] }, as: UTF8.self)
            }

            func size(at offset: Int) -> Int {
                Int(UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: offset, as: UInt32.self)))
            }

            guard raw.count >= 12, fourCC(at: 0) == "RIFF" else {
                throw FixtureError.malformed(relativePath)
            }

            var offset = 12

            while offset + 8 <= raw.count {
                let chunk = fourCC(at: offset)
                let length = size(at: offset + 4)

                guard offset + 8 + length <= raw.count else {
                    throw FixtureError.malformed(relativePath)
                }

                if chunk == "data" {
                    guard length % 4 == 0 else { throw FixtureError.malformed(relativePath) }

                    return (0 ..< length / 4).map { index in
                        Float(bitPattern: UInt32(littleEndian: raw.loadUnaligned(
                            fromByteOffset: offset + 8 + index * 4, as: UInt32.self)))
                    }
                }

                // A chunk's payload is padded to an even length; the padding is not counted
                // in its size, so the next chunk starts after it.
                offset += 8 + length + length % 2
            }

            throw FixtureError.malformed(relativePath)
        }
    }
}
