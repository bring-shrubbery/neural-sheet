import AppKit
import Foundation
import NeuralSheetCore
import Observation
import os

/// What the view shows and the commands it sends the unit. Main actor.
@Observable final class PluginViewModel {
    /// The output's sample rate, nil until the host has made the unit.
    var sampleRate: Double?

    /// Record / Arm / Stop and the take, nil until the host has made the unit.
    private(set) var capture: CaptureSession?

    /// The checkpoints in the App Group container, read again when the view appears and on
    /// Check Again (the user may have downloaded one in the app meanwhile).
    private(set) var models: PluginModels

    /// Set when Open NeuralSheet found no app to open.
    private(set) var appMissing = false

    /// The paths inside the extension's sandbox: the models and the settings in the group
    /// container (Audio Unit design §2, "Models and settings").
    @ObservationIgnored let paths: AppPaths

    @ObservationIgnored private weak var unit: NeuralSheetAudioUnit?

    let version: String = {
        let info = Bundle(for: NeuralSheetAUViewController.self).infoDictionary
        return info?["CFBundleShortVersionString"] as? String ?? ""
    }()

    /// The Mac app, opened by its bundle identifier wherever it is installed.
    static let appBundleIdentifier = "com.quassum.neuralsheet"

    init(paths: AppPaths = .standard) {
        self.paths = paths
        models = PluginModels(store: ModelStore(paths: paths))

        let installed = models.transcription.map(\.rawValue) + (models.stemsInstalled ? ["stems"] : [])
        Self.log.info("models in \(paths.models.path, privacy: .public): \(installed, privacy: .public)")
    }

    static let log = Logger(subsystem: "com.quassum.neuralsheet.plugin.au", category: "plugin")

    func connect(_ unit: NeuralSheetAudioUnit) {
        self.unit = unit
        capture = unit.capture
    }

    // MARK: - Capture

    func record() {
        unit?.startCapture()
    }

    func arm() {
        unit?.arm()
    }

    func stop() {
        unit?.stopCapture()
    }

    func clear() {
        capture?.clear()
    }

    // MARK: - Models

    func refreshModels() {
        let scanned = PluginModels(store: ModelStore(paths: paths))

        if scanned != models {
            models = scanned
        }
    }

    /// Open NeuralSheet, where the models are downloaded (Settings › Model).
    func openApp() {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: Self.appBundleIdentifier) else {
            appMissing = true
            return
        }

        appMissing = false
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration(), completionHandler: nil)
    }
}
