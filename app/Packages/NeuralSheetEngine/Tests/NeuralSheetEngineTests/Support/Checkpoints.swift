// Where the tests look for the real checkpoints. The engine never downloads one,
// so a test that needs weights skips when the machine has none rather than
// failing: a clean checkout must be able to run `swift test` offline.

import Foundation

enum CheckpointSize: String {
    case small, medium, large

    var fileName: String { "muscriptor-\(rawValue)-f16.gguf" }
}

enum Checkpoints {
    /// The directories a checkpoint may live in, in the order the app searches them:
    /// an explicit override first, then NeuralSheet's own model directory, then the
    /// one NeuralNote used, so a machine that ran the old app needs no second copy.
    private static var searchPaths: [URL] {
        var paths: [URL] = []

        if let override = ProcessInfo.processInfo.environment["NEURALSHEET_MODELS"], !override.isEmpty {
            paths.append(URL(filePath: override))
        }

        let home = FileManager.default.homeDirectoryForCurrentUser
        paths.append(home.appending(path: "Library/NeuralSheet/models"))
        paths.append(home.appending(path: "Library/NeuralNote/models"))
        return paths
    }

    /// The first installed checkpoint of this size, or nil when none is installed.
    static func url(for size: CheckpointSize) -> URL? {
        for directory in searchPaths {
            let candidate = directory.appending(path: size.fileName)

            if FileManager.default.fileExists(atPath: candidate.path(percentEncoded: false)) {
                return candidate
            }
        }

        return nil
    }
}
