import AVFoundation
import CoreAudioKit
import SwiftUI

/// The extension's principal class and its `AUAudioUnitFactory` (Audio Unit design §2, "UI"):
/// the host asks it for the audio unit, then for its view, a SwiftUI ``PluginView``.
final class NeuralSheetAUViewController: AUViewController, AUAudioUnitFactory {
    private let model = PluginViewModel()

    /// The output bus's format, watched for the sample rate. Released with the controller.
    private var formatObservation: NSKeyValueObservation?

    override func loadView() {
        view = NSHostingView(rootView: PluginView(model: model))
        preferredContentSize = NSSize(width: 720, height: 420)
    }

    /// Called by the host on a thread of its own, possibly before the view exists.
    nonisolated func createAudioUnit(with componentDescription: AudioComponentDescription) throws -> AUAudioUnit {
        let unit = try NeuralSheetAudioUnit(componentDescription: componentDescription, options: [])
        Task { @MainActor [weak self] in self?.connect(unit) }
        return unit
    }

    private func connect(_ unit: NeuralSheetAudioUnit) {
        let model = self.model
        model.connect(unit)
        // KVO may call back on the thread that changed the format; the model is the main actor's.
        formatObservation = unit.outputBusses[0].observe(\.format, options: [.initial, .new]) { bus, _ in
            let rate = bus.format.sampleRate
            Task { @MainActor in model.sampleRate = rate }
        }
    }
}
