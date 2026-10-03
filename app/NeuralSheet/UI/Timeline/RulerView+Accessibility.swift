import AppKit
import NeuralSheetCore

/// The ruler as VoiceOver sees it (a11y design §2): a slider whose value is the playhead -- its
/// time and its bar and beat -- that increment and decrement move a beat later or earlier, as a
/// click there would seek; its tempo and marker flags as buttons inside it that open the ruler's
/// card, as clicking or right-clicking them does; and VoiceOver's menu key opens the card for the
/// bar under the playhead, as a right-click there does.
extension RulerView: KeyboardFocusableView, OwnsArrowKeys {
    override func isAccessibilityElement() -> Bool { true }

    override func accessibilityRole() -> NSAccessibility.Role? { .slider }

    override func accessibilityLabel() -> String? {
        String(localized: "Ruler", comment: "VoiceOver: the time ruler above the piano roll; its value is the playhead")
    }

    override func accessibilityValue() -> Any? {
        guard canPlay, let seconds = accessibilityPlayhead?() else { return nil }

        let time = TimeFormat.transport(seconds)

        guard let tempoMap else { return time }

        let position = tempoMap.barBeat(at: seconds + 1e-6)

        return String(localized: "\(time), bar \(position.bar) beat \(position.beat)",
                      comment: "VoiceOver: the ruler's value, the playhead's time then its bar and beat")
    }

    override func accessibilityPerformIncrement() -> Bool {
        stepPlayhead(byBeats: 1)
    }

    override func accessibilityPerformDecrement() -> Bool {
        stepPlayhead(byBeats: -1)
    }

    /// The card for the bar under the playhead, at the playhead.
    override func accessibilityPerformShowMenu() -> Bool {
        guard canPlay, let tempoMap, let onTempoCard, let seconds = accessibilityPlayhead?() else { return false }

        let point = convert(CGPoint(x: geometry.x(forSeconds: seconds), y: bounds.midY), to: nil)
        onTempoCard(point, RulerCardTarget(bar: tempoMap.bar(atSeconds: seconds), seconds: seconds))

        return true
    }

    override func accessibilityChildren() -> [Any]? {
        accessibilityFlagElements()
    }

    /// To the next or the previous beat line of the meter, the one the ruler draws, so a step
    /// lands on a beat whatever the playhead was between; clamped to the take.
    private func stepPlayhead(byBeats beats: Int) -> Bool {
        guard canPlay, let tempoMap, let seconds = accessibilityPlayhead?() else { return false }

        let segment = tempoMap.segment(atSeconds: seconds)
        let beat = segment.timeSignature.beatLength * 60 / segment.bpm
        let epsilon = 1e-6
        let target: Double?

        if beats > 0 {
            target = tempoMap.beatLines(from: seconds + epsilon, to: seconds + 2 * beat)
                .first { $0.seconds > seconds + epsilon }?.seconds
        } else {
            target = tempoMap.beatLines(from: max(0, seconds - 2 * beat), to: seconds)
                .last { $0.seconds < seconds - epsilon }?.seconds
        }

        let next = min(max(0, target ?? seconds + Double(beats) * beat), geometry.duration)

        onSeek?(next)
        NSAccessibility.post(element: self, notification: .valueChanged)

        return true
    }

    // MARK: - Flags

    /// The tempo flags then the marker flags, as buttons; made again only when they change.
    private func accessibilityFlagElements() -> [DrawnElement] {
        let tempo = tempoFlags()
        let markers = markerFlags()
        let key = tempo.map { "t\($0.bar)\($0.label)" } + markers.map { "m\($0.id)\($0.name)\($0.seconds)" }

        if let cached = accessibilityFlags, cached.flags == key { return cached.elements }

        let tempoElements = tempo.map { flag in
            flagElement(frame: flag.frame,
                        label: String(localized: "Tempo change at bar \(flag.bar), \(flag.label)",
                                      comment: "VoiceOver: a tempo flag on the ruler, e.g. \"Tempo change at bar 9, 90 · 3/4\""),
                        target: RulerCardTarget(bar: flag.bar, seconds: tempoMap?.barStart(bar: flag.bar) ?? 0))
        }

        let markerElements = markers.map { flag in
            let bar = tempoMap?.bar(atSeconds: flag.seconds) ?? 1
            let name = flag.name.isEmpty
                ? String(localized: "Marker", comment: "VoiceOver: a marker flag with no name")
                : flag.name

            return flagElement(frame: flag.frame,
                               label: String(localized: "\(name), marker at bar \(bar)",
                                             comment: "VoiceOver: a section marker's flag on the ruler, e.g. \"Verse, marker at bar 5\""),
                               target: RulerCardTarget(bar: bar, seconds: flag.seconds, markerID: flag.id))
        }

        let elements = tempoElements + markerElements
        accessibilityFlags = (key, elements)

        return elements
    }

    private func flagElement(frame: CGRect, label: String, target: RulerCardTarget) -> DrawnElement {
        let element = DrawnElement(in: self, role: .button, rect: { frame }, label: { label })

        element.press = { [weak self, weak element] in
            guard let self, let onTempoCard, let point = element?.windowCentre else { return false }

            onTempoCard(point, target)
            return true
        }

        return element
    }

    // MARK: - Keyboard focus

    override var acceptsFirstResponder: Bool { acceptsKeyboardFocus }

    override func drawFocusRingMask() {
        NSBezierPath(rect: focusRingRect).fill()
    }

    override var focusRingMaskBounds: NSRect { focusRingRect }

    /// Focused, ← and → step the playhead a beat, as VoiceOver's decrement and increment do.
    override func keyDown(with event: NSEvent) {
        switch event.specialKey {
        case .leftArrow?: _ = accessibilityPerformDecrement()
        case .rightArrow?: _ = accessibilityPerformIncrement()
        default: super.keyDown(with: event)
        }
    }
}
