import AppKit
import NeuralSheetCore

/// The chord lane as VoiceOver sees it (a11y design §2): a group of the symbols in the band, each
/// a button read as its symbol and where it falls ("Am7, bar 3 beat 1") whose press opens its
/// card, as a click does. Made when VoiceOver asks; dropped when the labels or the band change.
extension ChordLaneView {
    override func isAccessibilityElement() -> Bool { !chords.isEmpty }

    override func accessibilityRole() -> NSAccessibility.Role? { .group }

    override func accessibilityLabel() -> String? {
        String(localized: "Chords", comment: "VoiceOver: the chord lane above the piano roll")
    }

    override func accessibilityChildren() -> [Any]? {
        if let accessibilityChords { return accessibilityChords }

        let start = geometry.seconds(forX: bounds.minX)
        let end = geometry.seconds(forX: bounds.maxX)
        let elements = chords.indices
            .filter { $0 < labels.count && chords[$0].seconds >= start && chords[$0].seconds <= end }
            .map(chordElement)

        accessibilityChords = elements

        return elements
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        invalidateAccessibilityChords()
    }

    override func setBoundsOrigin(_ newOrigin: NSPoint) {
        super.setBoundsOrigin(newOrigin)
        invalidateAccessibilityChords()
    }

    func invalidateAccessibilityChords() {
        guard accessibilityChords != nil else { return }

        accessibilityChords = nil
        NSAccessibility.post(element: self, notification: .layoutChanged)
    }

    private func chordElement(_ index: Int) -> DrawnElement {
        let event = chords[index]
        let position = grid.barBeat(at: event.seconds + 1e-6)
        let symbol = labels[index]
        let label = String(localized: "\(symbol), bar \(position.bar) beat \(position.beat)",
                           comment: "VoiceOver: a chord symbol in the chord lane, e.g. \"Am7, bar 3 beat 1\"")

        let element = DrawnElement(in: self, role: .button, rect: { [weak self] in
            guard let self else { return nil }

            let x = geometry.x(forSeconds: event.seconds)
            let next = index + 1 < chords.count ? geometry.x(forSeconds: chords[index + 1].seconds) : bounds.maxX

            return CGRect(x: x, y: 0, width: max(geometry.scale, next - x), height: bounds.height)
        }, label: { label })

        element.press = { [weak self, weak element] in
            guard let self, let onCard, let point = element?.windowCentre else { return false }

            onCard(point, index)
            return true
        }

        return element
    }
}
