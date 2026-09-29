// Ported from muscriptor.cpp's cpp/src/gguf_file.{hpp,cpp}, which delegates parsing
// to ggml's `gguf_init_from_file`. ggml is not linked here, so this is the GGUF
// spec's own little-endian layout read by hand:
// https://github.com/ggml-org/ggml/blob/master/docs/gguf.md

import Foundation

/// A bounds-checked cursor over a memory-mapped GGUF.
///
/// Every read goes through `requireRoom`, because the file is untrusted input: a
/// truncated or hand-edited checkpoint must come back as `.invalidCheckpoint` and
/// never as a read past the end of the mapping, which would be a crash the caller
/// cannot catch.
struct GGUFReader {
    private let bytes: UnsafeRawBufferPointer

    /// Bytes consumed so far, which after the tensor table is where the data section's
    /// alignment padding starts.
    private(set) var offset: Int

    init(bytes: UnsafeRawBufferPointer, offset: Int = 0) {
        self.bytes = bytes
        self.offset = offset
    }

    private func requireRoom(_ count: Int) throws {
        guard count >= 0, offset <= bytes.count, bytes.count - offset >= count else {
            throw TranscriberError.invalidCheckpoint("truncated")
        }
    }

    /// A little-endian integer of any width, which covers every fixed-size value type
    /// the spec has: the floats are read as their bit patterns.
    mutating func integer<T: FixedWidthInteger>(_ type: T.Type) throws -> T {
        let size = MemoryLayout<T>.size
        try requireRoom(size)
        // Unaligned: GGUF pads nothing before the data section, so a UInt64 can land on
        // any byte.
        let raw = bytes.loadUnaligned(fromByteOffset: offset, as: T.self)
        offset += size
        return T(littleEndian: raw)
    }

    /// An `Int` from a `UInt64` count or extent, rejecting a value this platform cannot
    /// index with rather than wrapping it.
    mutating func size() throws -> Int {
        let value = try integer(UInt64.self)

        guard let converted = Int(exactly: value) else {
            throw TranscriberError.invalidCheckpoint("implausible 64-bit count in the header")
        }

        return converted
    }

    mutating func magic() throws -> String {
        try requireRoom(4)
        let text = String(decoding: (0 ..< 4).map { bytes[offset + $0] }, as: UTF8.self)
        offset += 4
        return text
    }

    /// A GGUF string: a 64-bit length and that many UTF-8 bytes, not terminated.
    mutating func string() throws -> String {
        let length = try size()
        try requireRoom(length)
        let text = String(decoding: bytes[offset ..< (offset + length)], as: UTF8.self)
        offset += length
        return text
    }

    /// One metadata value, given the type code that preceded it.
    mutating func value(typeCode: UInt32) throws -> GGUFValue {
        switch typeCode {
        case 0: return .uint8(try integer(UInt8.self))
        case 1: return .int8(try integer(Int8.self))
        case 2: return .uint16(try integer(UInt16.self))
        case 3: return .int16(try integer(Int16.self))
        case 4: return .uint32(try integer(UInt32.self))
        case 5: return .int32(try integer(Int32.self))
        case 6: return .float32(Float(bitPattern: try integer(UInt32.self)))
        case 7: return .bool(try integer(UInt8.self) != 0)
        case 8: return .string(try string())
        case 9: return .array(try array())
        case 10: return .uint64(try integer(UInt64.self))
        case 11: return .int64(try integer(Int64.self))
        case 12: return .float64(Double(bitPattern: try integer(UInt64.self)))
        default:
            throw TranscriberError.invalidCheckpoint("metadata value type \(typeCode) is not one the spec defines")
        }
    }

    private mutating func array() throws -> [GGUFValue] {
        let elementType = try integer(UInt32.self)
        let count = try size()

        // The count is the file's word against the mapping's length, so nothing is
        // reserved beyond a sane amount: a corrupt count would otherwise ask for
        // gigabytes before the first element's bounds check rejected it.
        var values: [GGUFValue] = []
        values.reserveCapacity(min(count, 4096))

        for _ in 0 ..< count {
            values.append(try value(typeCode: elementType))
        }

        return values
    }

    /// One row of the tensor info table.
    mutating func tensorInfo() throws -> TensorInfo {
        let name = try string()
        let dimensions = try integer(UInt32.self)

        // ggml's hard limit, and the spec's: a file claiming more is not one ggml wrote.
        guard dimensions >= 1, dimensions <= 4 else {
            throw TranscriberError.invalidCheckpoint("tensor '\(name)' claims \(dimensions) dimensions")
        }

        var shape: [Int] = []
        shape.reserveCapacity(Int(dimensions))
        // The element count is multiplied out here rather than left to `TensorInfo`,
        // because four extents from an untrusted file can overflow `Int` and
        // `elementCount` would trap where this must throw.
        var elements = 1

        for _ in 0 ..< dimensions {
            let extent = try size()

            guard extent > 0 else {
                throw TranscriberError.invalidCheckpoint("tensor '\(name)' has an empty extent")
            }

            let (product, overflowed) = elements.multipliedReportingOverflow(by: extent)

            guard !overflowed else {
                throw TranscriberError.invalidCheckpoint("tensor '\(name)' claims more elements than can be indexed")
            }

            elements = product
            shape.append(extent)
        }

        let typeCode = try integer(UInt32.self)

        guard let dataType = TensorDataType(rawValue: typeCode) else {
            throw TranscriberError.invalidCheckpoint("tensor '\(name)' has element type \(typeCode), which this build "
                + "does not read")
        }

        // The extents fit `Int` but their product times the element size need not, and
        // `TensorInfo.byteCount` would trap on it before `GGUFFile` could bounds-check
        // the tensor against the mapping.
        guard case (_, false) = elements.multipliedReportingOverflow(by: dataType.byteSize) else {
            throw TranscriberError.invalidCheckpoint("tensor '\(name)' claims more bytes than can be addressed")
        }

        return TensorInfo(name: name, shape: shape, dataType: dataType, offset: try size())
    }
}
