// Ported from muscriptor.cpp's cpp/src/gguf_file.{hpp,cpp}, whose metadata
// accessors are ggml's `gguf_get_val_*`. ggml is not linked here, so the value
// types of the GGUF spec are modelled directly.

/// One GGUF metadata value. The spec's type codes are a closed set, so an enum with
/// one case per code keeps a wrong-type read a compile-time-exhaustive `switch`
/// rather than a family of `as?` casts.
enum GGUFValue: Equatable, Sendable {
    case uint8(UInt8)
    case int8(Int8)
    case uint16(UInt16)
    case int16(Int16)
    case uint32(UInt32)
    case int32(Int32)
    case float32(Float)
    case bool(Bool)
    case string(String)
    case array([GGUFValue])
    case uint64(UInt64)
    case int64(Int64)
    case float64(Double)
}
