import Foundation

/// What ``AppPaths/migrateToGroupContainer()`` did.
public struct GroupContainerMigration: Sendable, Equatable {
    /// The entries moved from `<root>/models` into `<group>/Models`.
    public var movedModels: [String] = []
    /// Whether `global.settings` moved into the group container.
    public var movedSettings = false
    /// Entries a move failed for; they stay where they were and are read from nowhere.
    public var failed: [String] = []

    public var didMove: Bool { !movedModels.isEmpty || movedSettings }
}

extension AppPaths {
    #if os(macOS)
    /// The group container: what the system answers for the group when it answers (always inside
    /// the extension's sandbox, which holds the entitlement), else the literal path under the
    /// user's real home. The Mac app is not sandboxed and reads the folder directly, so the
    /// literal path is as good as the system's answer for it.
    static func groupContainerURL() -> URL {
        if let url = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupIdentifier) {
            return url
        }

        return realHome()
            .appendingPathComponent("Library/Group Containers", isDirectory: true)
            .appendingPathComponent(appGroupIdentifier, isDirectory: true)
    }

    /// The group container when this process may use it, else nil, and the models and settings
    /// stay under ``root`` as before the group. A copy signed by another team (a contributor's
    /// build) or ad hoc is not let into the container (macOS guards group containers by the
    /// signature's team), and a Mac app that cannot read its models would be worse than one that
    /// keeps them where they were.
    static func usableGroupContainer() -> URL? {
        let url = groupContainerURL()
        let manager = FileManager.default
        try? manager.createDirectory(at: url, withIntermediateDirectories: true)
        return (try? manager.contentsOfDirectory(atPath: url.path)) != nil ? url : nil
    }

    /// The user's home from the password database, which a sandbox does not redirect.
    private static func realHome() -> URL {
        if let entry = getpwuid(getuid()), let dir = entry.pointee.pw_dir {
            return URL(fileURLWithPath: String(cString: dir), isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
    }
    #endif

    /// The one-time move of the Mac app's models and settings into the group container (Audio
    /// Unit design §2, "Models and settings"), run at launch before anything reads them.
    ///
    /// - The models move when `<root>/models` has files and `<group>/Models` has none. When the
    ///   new folder already has files (a later launch, or a copy put there by hand) the old ones
    ///   are left alone: nothing is overwritten and nothing is deleted.
    /// - `global.settings` moves when the group container has none, on its own terms, so a user
    ///   with settings but no models keeps them too.
    /// - Moves are renames (the group container is under the same `~/Library`); the emptied old
    ///   folder stays. The recordings and projects do not move.
    ///
    /// Quiet when there is no group container (iOS) or nothing to move.
    @discardableResult
    public func migrateToGroupContainer() -> GroupContainerMigration {
        var outcome = GroupContainerMigration()

        guard groupContainer != nil, models.standardizedFileURL != legacyModels.standardizedFileURL else {
            return outcome
        }

        let manager = FileManager.default

        let legacy = Self.visibleEntries(in: legacyModels)
        if !legacy.isEmpty, Self.visibleEntries(in: models).isEmpty {
            do {
                try manager.createDirectory(at: models, withIntermediateDirectories: true)
                for entry in legacy {
                    let name = entry.lastPathComponent
                    do {
                        try manager.moveItem(at: entry, to: models.appendingPathComponent(name))
                        outcome.movedModels.append(name)
                    } catch {
                        outcome.failed.append(name)
                    }
                }
            } catch {
                outcome.failed.append(contentsOf: legacy.map(\.lastPathComponent))
            }
        }

        if manager.fileExists(atPath: legacyGlobalSettings.path), !manager.fileExists(atPath: globalSettings.path) {
            do {
                try manager.createDirectory(at: globalSettings.deletingLastPathComponent(),
                                            withIntermediateDirectories: true)
                try manager.moveItem(at: legacyGlobalSettings, to: globalSettings)
                outcome.movedSettings = true
            } catch {
                outcome.failed.append(legacyGlobalSettings.lastPathComponent)
            }
        }

        return outcome
    }

    /// The folder's entries without the Finder's hidden files; empty when it does not exist.
    private static func visibleEntries(in directory: URL) -> [URL] {
        let entries = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
        return (entries ?? []).sorted { $0.lastPathComponent < $1.lastPathComponent }
    }
}
