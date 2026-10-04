import Foundation

/// *Open in NeuralSheet* (Audio Unit design §2): the Audio Unit's sandboxed extension writes a
/// project package into the App Group container, `<group>/Handoff/<uuid>/<name>.neuralsheet`,
/// and asks the app to open it through the `neuralsheet://open` URL. The app moves the package
/// into ``handoffProjects`` (the extension cannot write there), opens it from there and removes
/// the `<uuid>` folder. A handoff the app never received is swept at the next launch.
extension AppPaths {
    /// `<group>/Handoff`, nil without a group container (iOS, a build the system keeps out).
    public var handoff: URL? {
        groupContainer?.appendingPathComponent("Handoff", isDirectory: true)
    }

    /// `~/Music/NeuralSheet`: where a handed-off project lands. The app has no projects folder
    /// of its own; its save panel starts in ``musicFolder``.
    public var handoffProjects: URL {
        musicFolder.appendingPathComponent("NeuralSheet", isDirectory: true)
    }

    /// How long an unclaimed handoff is kept: a day, so a launch while the plugin is writing one
    /// never takes it away.
    public static let handoffLifetime: TimeInterval = 24 * 60 * 60

    /// Removes the handoff folders last modified more than ``handoffLifetime`` before `now`.
    /// Quiet when there is no handoff folder.
    public func sweepHandoff(now: Date = Date()) {
        guard let handoff else { return }

        let manager = FileManager.default

        guard let entries = try? manager.contentsOfDirectory(
            at: handoff, includingPropertiesForKeys: [.contentModificationDateKey])
        else { return }

        for entry in entries {
            let modified = (try? entry.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate

            if let modified, now.timeIntervalSince(modified) <= Self.handoffLifetime { continue }

            try? manager.removeItem(at: entry)
        }
    }

    /// Moves the handed-off package at `package` (inside `<handoff>/<uuid>/`, already validated)
    /// into ``handoffProjects`` under a name no file there has yet, removes its `<uuid>` folder,
    /// and returns where the package is now.
    public func adoptHandoff(_ package: URL) throws -> URL {
        let manager = FileManager.default
        let folder = handoffProjects

        do {
            try manager.createDirectory(at: folder, withIntermediateDirectories: true)

            let destination = Self.uniqueURL(in: folder, base: package.deletingPathExtension().lastPathComponent,
                                             pathExtension: package.pathExtension)
            try manager.moveItem(at: package, to: destination)
            try? manager.removeItem(at: package.deletingLastPathComponent())

            return destination
        } catch {
            throw ProjectError.couldNotWrite(error.localizedDescription)
        }
    }

    /// `<folder>/<base>.<ext>`, or `<base> 2.<ext>`, `<base> 3.<ext>`… for the first that is free,
    /// as the Finder numbers a copy.
    static func uniqueURL(in folder: URL, base: String, pathExtension: String) -> URL {
        let manager = FileManager.default
        var candidate = folder.appendingPathComponent(base).appendingPathExtension(pathExtension)
        var number = 2

        while manager.fileExists(atPath: candidate.path) {
            candidate = folder.appendingPathComponent("\(base) \(number)").appendingPathExtension(pathExtension)
            number += 1
        }

        return candidate
    }
}
