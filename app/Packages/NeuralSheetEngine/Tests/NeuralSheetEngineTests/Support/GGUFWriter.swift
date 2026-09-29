// A GGUF writer that exists only so the reader can be tested without a
// checkpoint: the real files are 100 MB and not in the repository, and a reader
// has to be exercised on values it will never see in one (every scalar type, a
// string array, a truncated tail). Writing is the reader's mirror image, so the
// two disagreeing is a real failure and not a shared mistake only if this stays
// a literal transcription of the spec rather than a call into the reader.

import Foundation

@testable import NeuralSheetEngine

/// A GGUF built in memory, with the offsets the reader is expected to derive so a
/// test can assert them and can cut the file at a known point.
struct GGUFBlob {
    var data: Data

    /// Where the tensor info table starts, i.e. the end of the key/value section.
    var tensorInfoStart: Int

    /// Where the tensor info table ends, before the alignment padding.
    var tensorInfoEnd: Int

    /// Where the data section starts: `tensorInfoEnd` rounded up to the alignment.
    var dataStart: Int
}

struct GGUFWriter {
    /// Overridable so a test can write something that is not a GGUF at all.
    var magic = "GGUF"
    var version: UInt32 = 3
    var alignment = 32

    /// Kept as an array, not a dictionary, because the reader is expected to return
    /// the tensors in file order and a test asserting that needs a defined order.
    private(set) var metadata: [(key: String, value: GGUFValue)] = []
    private(set) var tensors: [(name: String, shape: [Int], dataType: TensorDataType, bytes: [UInt8])] = []

    mutating func set(_ key: String, _ value: GGUFValue) {
        if let index = metadata.firstIndex(where: { $0.key == key }) {
            metadata[index].value = value
        } else {
            metadata.append((key, value))
        }
    }

    mutating func remove(_ key: String) {
        metadata.removeAll { $0.key == key }
    }

    /// Adds a tensor whose payload is `values` encoded in `dataType`.
    mutating func addTensor(_ name: String, shape: [Int], dataType: TensorDataType, values: [Float]) {
        tensors.append((name, shape, dataType, GGUFWriter.encode(values, as: dataType)))
    }

    /// The bytes a tensor's payload is stored as, which is also what a test compares
    /// `bytes(of:)` against.
    static func encode(_ values: [Float], as dataType: TensorDataType) -> [UInt8] {
        switch dataType {
        case .f32:
            return values.flatMap { littleEndianBytes($0.bitPattern) }
        case .f16:
            return values.flatMap { littleEndianBytes(Float16($0).bitPattern) }
        }
    }

    private static func littleEndianBytes<T: FixedWidthInteger>(_ value: T) -> [UInt8] {
        withUnsafeBytes(of: value.littleEndian) { Array($0) }
    }

    func build() -> GGUFBlob {
        var out = Data()
        out.append(contentsOf: Array(magic.utf8))
        append(UInt32(version), to: &out)
        append(UInt64(tensors.count), to: &out)
        append(UInt64(metadata.count), to: &out)

        for entry in metadata {
            appendString(entry.key, to: &out)
            append(UInt32(GGUFWriter.typeCode(of: entry.value)), to: &out)
            appendValue(entry.value, to: &out)
        }

        let tensorInfoStart = out.count

        // Each tensor's payload is padded to the alignment, because GGUF requires
        // every tensor offset to be a multiple of it.
        var payload = Data()

        for tensor in tensors {
            appendString(tensor.name, to: &out)
            append(UInt32(tensor.shape.count), to: &out)

            for extent in tensor.shape {
                append(UInt64(extent), to: &out)
            }

            append(tensor.dataType.rawValue, to: &out)
            append(UInt64(payload.count), to: &out)

            payload.append(contentsOf: tensor.bytes)
            payload.append(contentsOf: [UInt8](repeating: 0, count: padding(for: payload.count)))
        }

        let tensorInfoEnd = out.count
        out.append(contentsOf: [UInt8](repeating: 0, count: padding(for: out.count)))
        let dataStart = out.count
        out.append(payload)

        return GGUFBlob(
            data: out, tensorInfoStart: tensorInfoStart, tensorInfoEnd: tensorInfoEnd, dataStart: dataStart)
    }

    private func padding(for length: Int) -> Int {
        let remainder = length % alignment
        return remainder == 0 ? 0 : alignment - remainder
    }

    private func append<T: FixedWidthInteger>(_ value: T, to out: inout Data) {
        out.append(contentsOf: GGUFWriter.littleEndianBytes(value))
    }

    private func appendString(_ string: String, to out: inout Data) {
        let bytes = Array(string.utf8)
        append(UInt64(bytes.count), to: &out)
        out.append(contentsOf: bytes)
    }

    private func appendValue(_ value: GGUFValue, to out: inout Data) {
        switch value {
        case .uint8(let v): append(v, to: &out)
        case .int8(let v): append(v, to: &out)
        case .uint16(let v): append(v, to: &out)
        case .int16(let v): append(v, to: &out)
        case .uint32(let v): append(v, to: &out)
        case .int32(let v): append(v, to: &out)
        case .float32(let v): append(v.bitPattern, to: &out)
        case .bool(let v): append(UInt8(v ? 1 : 0), to: &out)
        case .string(let v): appendString(v, to: &out)
        case .uint64(let v): append(v, to: &out)
        case .int64(let v): append(v, to: &out)
        case .float64(let v): append(v.bitPattern, to: &out)
        case .array(let values):
            // An empty array has no element type to write, so the writer refuses one
            // rather than invent a code the reader would have to guess at.
            append(UInt32(GGUFWriter.typeCode(of: values[0])), to: &out)
            append(UInt64(values.count), to: &out)

            for element in values {
                appendValue(element, to: &out)
            }
        }
    }

    /// The spec's value type codes, written out here rather than asked of the reader.
    static func typeCode(of value: GGUFValue) -> UInt32 {
        switch value {
        case .uint8: return 0
        case .int8: return 1
        case .uint16: return 2
        case .int16: return 3
        case .uint32: return 4
        case .int32: return 5
        case .float32: return 6
        case .bool: return 7
        case .string: return 8
        case .array: return 9
        case .uint64: return 10
        case .int64: return 11
        case .float64: return 12
        }
    }
}

/// Writes `data` to a throwaway file, hands its URL to `body` and removes it after.
func withTemporaryFile<T>(_ data: Data, _ body: (URL) throws -> T) throws -> T {
    let url = FileManager.default.temporaryDirectory.appending(path: "NeuralSheetEngine-\(UUID().uuidString).gguf")
    try data.write(to: url)
    defer { try? FileManager.default.removeItem(at: url) }
    return try body(url)
}
