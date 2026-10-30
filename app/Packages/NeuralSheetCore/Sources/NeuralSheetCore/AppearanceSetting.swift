/// Settings → General → Appearance (native chrome design §2): whether the app follows the Mac's
/// Light / Dark setting or keeps one of its own.
public enum AppearanceSetting: String, Codable, CaseIterable, Sendable {
    /// Whatever System Settings → Appearance says, followed live.
    case system
    case light
    case dark
}
