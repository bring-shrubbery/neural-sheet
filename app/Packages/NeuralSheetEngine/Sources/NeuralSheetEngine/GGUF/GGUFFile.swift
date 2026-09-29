// Ported from muscriptor.cpp's cpp/src/gguf_file.{hpp,cpp}, minus ggml: the C++
// uploads every tensor into a backend buffer at load, while this maps the file and
// leaves the bytes where they are. The checkpoints are 100 MB to 1 GB and mostly
// read once, so mapping saves a second copy and lets the kernel page it back out.

import Foundation

/// A memory-mapped GGUF, parsed once into its metadata and tensor table.
///
/// The mapping lives as long as the instance, and `bytes(of:)` hands out pointers
/// into it, so a caller must keep the file alive while it reads. One call at a time;
/// nothing here is mutated after `init`.
final class GGUFFile {
    let url: URL
    let metadata: [String: GGUFValue]
    let tensors: [String: TensorInfo]

    /// File order, which is how the reference reports the tensor table.
    let tensorInfos: [TensorInfo]

    let alignment: Int

    /// Absolute: the tensor offsets in `tensorInfos` are relative to this.
    let dataOffset: Int

    private let mapping: UnsafeRawPointer
    private let mappedSize: Int

    /// `.fileNotFound` when there is no regular file at `url`; `.invalidCheckpoint`
    /// when there is one but it is not a GGUF this build reads, or it is cut short.
    init(url: URL) throws {
        self.url = url
        let path = url.path(percentEncoded: false)

        // Existence is separated from readability, as in the C++: a caller telling the
        // user why a checkpoint was rejected needs "wrong path" apart from "wrong file".
        let descriptor = path.withCString { open($0, O_RDONLY) }

        guard descriptor >= 0 else {
            throw TranscriberError.fileNotFound("checkpoint not found: \(path)")
        }

        var status = stat()
        let stated = fstat(descriptor, &status)
        let isRegularFile = stated == 0 && (status.st_mode & S_IFMT) == S_IFREG
        let size = Int(status.st_size)

        guard isRegularFile else {
            close(descriptor)
            throw TranscriberError.fileNotFound("checkpoint is not a regular file: \(path)")
        }

        // mmap rejects a zero length, and an empty file is not a GGUF anyway.
        guard size > 0, let raw = mmap(nil, size, PROT_READ, MAP_PRIVATE, descriptor, 0), raw != MAP_FAILED else {
            close(descriptor)
            throw TranscriberError.invalidCheckpoint("could not map \(path)")
        }

        // The mapping outlives the descriptor, so the file is closed straight away
        // rather than held open for the life of the model.
        close(descriptor)
        mapping = UnsafeRawPointer(raw)
        mappedSize = size

        // A throwing initialiser runs no deinit, so the mapping is released by hand on
        // every failing path out of the parse.
        do {
            let header = try GGUFFile.parse(
                bytes: UnsafeRawBufferPointer(start: mapping, count: mappedSize), name: url.lastPathComponent)
            metadata = header.metadata
            tensorInfos = header.tensorInfos
            tensors = header.tensors
            alignment = header.alignment
            dataOffset = header.dataOffset
        } catch {
            munmap(raw, size)
            throw error
        }
    }

    deinit {
        munmap(UnsafeMutableRawPointer(mutating: mapping), mappedSize)
    }

    private struct Header {
        var metadata: [String: GGUFValue]
        var tensorInfos: [TensorInfo]
        var tensors: [String: TensorInfo]
        var alignment: Int
        var dataOffset: Int
    }

    private static func parse(bytes: UnsafeRawBufferPointer, name: String) throws -> Header {
        var reader = GGUFReader(bytes: bytes)

        guard try reader.magic() == "GGUF" else {
            throw TranscriberError.invalidCheckpoint("not a readable GGUF file: \(name)")
        }

        let version = try reader.integer(UInt32.self)

        // v1 counted tensors and keys in 32 bits; v2 widened them and v3 only changed
        // what an array may hold, so the two the converter writes share this layout.
        guard version == 2 || version == 3 else {
            throw TranscriberError.invalidCheckpoint("\(name) is GGUF version \(version); this build reads 2 and 3")
        }

        let tensorCount = try reader.size()
        let keyCount = try reader.size()

        // The smallest a key/value pair or tensor row can be, so a count that could not
        // possibly fit is rejected before it is looped over.
        guard tensorCount <= bytes.count / 24, keyCount <= bytes.count / 12 else {
            throw TranscriberError.invalidCheckpoint("truncated")
        }

        var metadata: [String: GGUFValue] = [:]
        metadata.reserveCapacity(keyCount)

        for _ in 0 ..< keyCount {
            let key = try reader.string()
            let typeCode = try reader.integer(UInt32.self)
            metadata[key] = try reader.value(typeCode: typeCode)
        }

        var tensorInfos: [TensorInfo] = []
        tensorInfos.reserveCapacity(tensorCount)

        for _ in 0 ..< tensorCount {
            tensorInfos.append(try reader.tensorInfo())
        }

        let alignment = try GGUFFile.alignment(from: metadata, name: name)
        let remainder = reader.offset % alignment
        let dataOffset = remainder == 0 ? reader.offset : reader.offset + alignment - remainder

        guard dataOffset <= bytes.count else {
            throw TranscriberError.invalidCheckpoint("truncated")
        }

        // Every tensor is checked against the mapping now, so `bytes(of:)` needs no
        // bounds check of its own and the render-side readers stay branch-free.
        for info in tensorInfos {
            guard info.offset >= 0, bytes.count - dataOffset - info.offset >= info.byteCount else {
                throw TranscriberError.invalidCheckpoint(
                    "truncated: tensor '\(info.name)' runs past the end of \(name)")
            }
        }

        var tensors: [String: TensorInfo] = [:]
        tensors.reserveCapacity(tensorCount)

        for info in tensorInfos {
            tensors[info.name] = info
        }

        return Header(
            metadata: metadata, tensorInfos: tensorInfos, tensors: tensors, alignment: alignment,
            dataOffset: dataOffset)
    }

    /// The spec's default is 32, overridable by `general.alignment`.
    private static func alignment(from metadata: [String: GGUFValue], name: String) throws -> Int {
        guard let value = metadata["general.alignment"] else { return 32 }

        let requested: Int

        switch value {
        case .uint32(let raw): requested = Int(raw)
        case .int32(let raw): requested = Int(raw)
        case .uint64(let raw): requested = Int(clamping: raw)
        default:
            throw TranscriberError.invalidCheckpoint("general.alignment in \(name) is not an integer")
        }

        guard requested > 0, requested & (requested - 1) == 0 else {
            throw TranscriberError.invalidCheckpoint("general.alignment in \(name) is \(requested), not a power of two")
        }

        return requested
    }

    func has(_ key: String) -> Bool {
        metadata[key] != nil
    }

    /// The key's value as an `Int32`. A key that is absent or holds another type is an
    /// error and not a default, so a stale checkpoint fails at load rather than
    /// transcribing something subtly wrong.
    func int32(_ key: String) throws -> Int32 {
        guard case .int32(let value)? = metadata[key] else {
            throw missing(key, "an int32")
        }

        return value
    }

    /// @see int32
    func float32(_ key: String) throws -> Float {
        guard case .float32(let value)? = metadata[key] else {
            throw missing(key, "a float32")
        }

        return value
    }

    private func missing(_ key: String, _ expected: String) -> TranscriberError {
        .invalidCheckpoint("metadata key '\(key)' is not \(expected) in \(url.lastPathComponent)")
    }

    func tensor(named name: String) throws -> TensorInfo {
        guard let info = tensors[name] else {
            throw TranscriberError.invalidCheckpoint("tensor '\(name)' not found in \(url.lastPathComponent)")
        }

        return info
    }

    /// The tensor's bytes inside the mapping, valid while this file lives. `init` has
    /// already checked that the range is inside the mapping, for a tensor that came
    /// from this file.
    func bytes(of tensor: TensorInfo) -> UnsafeRawBufferPointer {
        UnsafeRawBufferPointer(start: mapping + dataOffset + tensor.offset, count: tensor.byteCount)
    }

    var dataSection: UnsafeRawBufferPointer {
        UnsafeRawBufferPointer(start: mapping + dataOffset, count: mappedSize - dataOffset)
    }

    /// The tensor's values as F32, converting from F16 where that is how it is stored:
    /// the C++ `tensorToFloat`.
    func floats(of tensor: TensorInfo) throws -> [Float] {
        guard tensors[tensor.name] == tensor else {
            throw TranscriberError.invalidCheckpoint("tensor '\(tensor.name)' is not one of \(url.lastPathComponent)'s")
        }

        let raw = bytes(of: tensor)
        let count = tensor.elementCount

        // Spelled out step by step: nested initialisers in one expression are more than
        // Xcode 26's type checker resolves in a Release build ("argument passed to call
        // that takes no arguments"), and the release runner builds with that Xcode.
        switch tensor.dataType {
        case .f32:
            return (0 ..< count).map { index -> Float in
                let bits = raw.loadUnaligned(fromByteOffset: index * 4, as: UInt32.self)
                return Float(bitPattern: UInt32(littleEndian: bits))
            }
        case .f16:
            return (0 ..< count).map { index -> Float in
                let bits = raw.loadUnaligned(fromByteOffset: index * 2, as: UInt16.self)
                let half = Float16(bitPattern: UInt16(littleEndian: bits))
                return Float(half)
            }
        }
    }
}
