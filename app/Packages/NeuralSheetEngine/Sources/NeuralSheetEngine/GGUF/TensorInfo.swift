// Ported from muscriptor.cpp's cpp/src/gguf_file.{hpp,cpp}: what the C++ reads off
// a `ggml_tensor` (name, `ne`, type, `nbytes`) without a ggml context to hold it.

/// The tensor element types a muscriptor checkpoint uses. `msl-convert` writes F16 or
/// F32 and nothing else, and the engine reads no quantised block type, so a fourth
/// code in a file is a file this build cannot use rather than something to skip.
enum TensorDataType: UInt32, Sendable {
    case f32 = 0
    case f16 = 1

    var byteSize: Int {
        switch self {
        case .f32: return 4
        case .f16: return 2
        }
    }
}

/// Where one tensor's bytes are and how to read them.
struct TensorInfo: Equatable, Sendable {
    var name: String

    /// ggml's `ne`, innermost extent first. Weights keep torch's `(out, in)` layout,
    /// which GGUF stores as `[in, out]`, so a matrix's shape reads back reversed from
    /// the safetensors it was converted from.
    var shape: [Int]

    var dataType: TensorDataType

    /// Bytes from the start of the data section, not from the start of the file.
    var offset: Int

    var elementCount: Int { shape.reduce(1, *) }

    var byteCount: Int { elementCount * dataType.byteSize }
}
