/// Which tab the window shows. In the core package because the project stores it -- `transcribe`
/// or `edit` only: a project saved in the Score tab writes `edit`, so the file opens in a version
/// without the tab (score design §2).
public enum Workspace: String, Codable, Sendable {
    case transcribe, edit, score

    /// What the project file stores for this tab.
    public var savedWorkspace: Workspace { self == .score ? .edit : self }
}
