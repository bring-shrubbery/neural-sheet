import Foundation
import Observation

/// What the view shows and the commands it sends the unit. Main actor.
@Observable final class PluginViewModel {
    /// The output's sample rate, nil until the host has made the unit.
    var sampleRate: Double?

    /// Record / Arm / Stop and the take, nil until the host has made the unit.
    private(set) var capture: CaptureSession?

    @ObservationIgnored private weak var unit: NeuralSheetAudioUnit?

    let version: String = {
        let info = Bundle(for: NeuralSheetAUViewController.self).infoDictionary
        return info?["CFBundleShortVersionString"] as? String ?? ""
    }()

    func connect(_ unit: NeuralSheetAudioUnit) {
        self.unit = unit
        capture = unit.capture
    }

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
}
