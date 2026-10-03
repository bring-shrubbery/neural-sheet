import AppKit
import NeuralSheetCore

/// The waveform strip as VoiceOver sees it (a11y design §2): a level indicator whose value is
/// the level playing now, the master meter's. While nothing is loaded its help says what the
/// drop zone does.
extension WaveformView {
    override func isAccessibilityElement() -> Bool { true }

    override func accessibilityRole() -> NSAccessibility.Role? { .levelIndicator }

    override func accessibilityLabel() -> String? {
        String(localized: "Waveform", comment: "VoiceOver: the take's waveform strip above the ruler")
    }

    override func accessibilityValue() -> Any? {
        guard let db = accessibilityLevel?(), db > MeterScale.minDb else {
            return String(localized: "Silent", comment: "VoiceOver: the waveform's level while nothing plays")
        }

        return String(localized: AccessibilityText.decibels(db))
    }

    override func accessibilityHelp() -> String? {
        guard (peaks?.sampleCount ?? 0) == 0 else { return nil }

        return String(localized: "Load an audio file, or drop one here",
                      comment: "VoiceOver: the empty waveform's help, which is where a file can be dropped")
    }
}
