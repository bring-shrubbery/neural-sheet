import Foundation

/// The recording input as the global settings remember it (system audio design §2): a hardware
/// input by its UID, System Audio, or one app by its bundle id. Only the app knows how to find
/// either again; this is the string and nothing else.
public enum RecordingInputSetting: Equatable, Sendable {
    case device(uid: String)
    case systemAudio
    case app(bundleID: String)

    /// `device:<uid>`, `system` or `app:<bundleID>`.
    public var encoded: String {
        switch self {
        case .device(let uid): "device:\(uid)"
        case .systemAudio: "system"
        case .app(let bundleID): "app:\(bundleID)"
        }
    }

    /// The setting a stored string names, or nil -- the system default -- for an empty string or
    /// one this version does not understand. Split at the first colon only: a device UID has
    /// colons of its own (`AppleUSBAudioEngine:Apple Inc.:…`).
    public init?(encoded: String) {
        if encoded == "system" {
            self = .systemAudio
            return
        }

        guard let colon = encoded.firstIndex(of: ":") else { return nil }

        let value = String(encoded[encoded.index(after: colon)...])
        guard !value.isEmpty else { return nil }

        switch encoded[..<colon] {
        case "device": self = .device(uid: value)
        case "app": self = .app(bundleID: value)
        default: return nil
        }
    }
}
