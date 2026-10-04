import Foundation
import NeuralSheetCore

/// The checkpoints the extension can use (Audio Unit design §2, "Models and settings"): the ones
/// the app downloaded into the App Group container, which ``AppPaths/standard`` resolves to inside
/// the extension's sandbox. The plugin downloads nothing itself; with no transcription model the
/// view sends the user to the app's Settings.
///
/// Free of AU types (design §3).
nonisolated struct PluginModels: Equatable, Sendable {
    /// The transcription sizes installed, in the app's order (small, medium, large).
    var transcription: [ModelSize]

    /// Whether the Demucs weights are installed, which the Stems option needs.
    var stemsInstalled: Bool

    /// The folder the checkpoints were looked for in, for the "no model" notice and the log.
    var folder: URL

    /// Nothing to transcribe with: the view's "Download models in NeuralSheet" state.
    var isEmpty: Bool { transcription.isEmpty }

    init(transcription: [ModelSize], stemsInstalled: Bool, folder: URL) {
        self.transcription = transcription
        self.stemsInstalled = stemsInstalled
        self.folder = folder
    }

    /// What `store` finds now.
    init(store: ModelStore) {
        let installed = store.installed()
        transcription = ModelSize.transcription.filter(installed.contains)
        stemsInstalled = installed.contains(.stems)
        folder = store.paths.models
    }

    /// The size a run uses: the one picked in the view while it is installed, else the app's
    /// setting (`global.settings`, shared through the group), else the default, else any installed
    /// size, as ``ModelStore/resolve(preferred:)`` falls back. Nil when none is installed.
    func size(picked: ModelSize?, preferred: ModelSize?) -> ModelSize? {
        for candidate in [picked, preferred, ModelManifest.defaultSize] {
            if let candidate, transcription.contains(candidate) { return candidate }
        }

        return transcription.first
    }
}
