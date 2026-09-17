import Foundation

/// One of the three transcription checkpoints the app can download.
public enum ModelSize: String, CaseIterable, Codable, Sendable {
    case small
    case medium
    case large

    /// The name shown in the model panel.
    public var displayName: String {
        switch self {
        case .small: "Small"
        case .medium: "Medium"
        case .large: "Large"
        }
    }

    /// The trade-off shown next to the size in the model panel.
    public var hint: String {
        switch self {
        case .small: "Fastest"
        case .medium: "Recommended"
        case .large: "Largest, slowest"
        }
    }
}

/// Everything the app needs to fetch and recognise one checkpoint.
///
/// The digest is compiled in rather than read from the repository, so a file that changed upstream
/// fails verification instead of being trusted.
public struct ModelSpec: Sendable {
    public let size: ModelSize
    public let fileName: String
    public let byteSize: Int64
    public let sha256Hex: String
    public var url: URL

    /// `<name>.gguf.<first 8 hex of sha256>.part`: a partial file is tied to the digest it is for,
    /// so a build pinned to other weights never appends to it.
    public var partFileName: String { "\(fileName).\(sha256Hex.prefix(8)).part" }

    /// - Parameter url: Where to fetch it from; by default its place in the pinned repository.
    public init(size: ModelSize, fileName: String, byteSize: Int64, sha256Hex: String, url: URL? = nil) {
        self.size = size
        self.fileName = fileName
        self.byteSize = byteSize
        self.sha256Hex = sha256Hex
        self.url = url ?? ModelManifest.url(forFileName: fileName)
    }
}

/// The checkpoints this build downloads, pinned to one commit of the published repository.
///
/// New weights mean a new revision and new entries, changed together.
public enum ModelManifest {
    public static let host = "huggingface.co"
    public static let repo = "DamRsn/muscriptor-gguf"
    public static let revision = "d7045f94e8b19427f4ff9542975035e66596e51c"

    /// Named for the checkpoint format generation, `muscriptor.format_version` in the GGUF.
    public static let repoDirectory = "v1"

    /// The size used when nothing else is known.
    public static let defaultSize: ModelSize = .medium

    public static func url(forFileName fileName: String) -> URL {
        // Constant components, so this cannot fail.
        URL(string: "https://\(host)/\(repo)/resolve/\(revision)/\(repoDirectory)/\(fileName)")!
    }

    public static func spec(for size: ModelSize) -> ModelSpec {
        switch size {
        case .small:
            ModelSpec(
                size: .small, fileName: "muscriptor-small-f16.gguf", byteSize: 209_425_152,
                sha256Hex: "925f55af65a20ebc4f8b45ceaf095a12b72493d436cb112623cd0041a1af23d4")
        case .medium:
            ModelSpec(
                size: .medium, fileName: "muscriptor-medium-f16.gguf", byteSize: 618_442_496,
                sha256Hex: "3850cc9e5b436b17a09bd25b8f2615cb3366ab96a71e7b50f73a793a917fdf03")
        case .large:
            ModelSpec(
                size: .large, fileName: "muscriptor-large-f16.gguf", byteSize: 2_739_142_176,
                sha256Hex: "35a750fb1ab1e77195cdc2c0b9b4aeea2f4d59f11f729f02af9920c4854ef72e")
        }
    }

    public static let all: [ModelSpec] = ModelSize.allCases.map(spec(for:))
}
