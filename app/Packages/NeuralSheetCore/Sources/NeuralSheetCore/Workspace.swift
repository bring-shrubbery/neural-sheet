/// Which tab the window shows. In the core package because the session stores it.
public enum Workspace: String, Codable, Sendable {
    case transcribe, edit
}
