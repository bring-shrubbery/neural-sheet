import AppKit
import NeuralSheetCore

/// The key column left of the piano roll (`Keyboard`, a `KeyboardComponentBase` facing right):
/// white keys with a 1 px gap on their bottom and right edges, black keys with a 1 px bottom gap,
/// every C labelled, and the whole column blended 40 % toward the gutter while there are no notes.
final class KeyboardView: NSView {
    let geometry: TimelineGeometry

    /// `Keyboard::setDimmed`: the column falls back while the roll beside it is empty.
    var isDimmed = false {
        didSet {
            if isDimmed != oldValue {
                needsDisplay = true
            }
        }
    }

    /// A wheel gesture over the keys scrolls pitch; the container applies it to the geometry and
    /// repaints the roll with it.
    var onWheel: ((NSEvent) -> Void)?

    init(geometry: TimelineGeometry) {
        self.geometry = geometry
        super.init(frame: .zero)
        wantsLayer = true
        clipsToBounds = true
    }

    required init?(coder: NSCoder) {
        nil
    }

    override var isFlipped: Bool { true }

    override var isOpaque: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }

        let k = geometry.scale
        let range = geometry.pitchRange

        // `Keyboard::drawKeyboardBackground`.
        ctx.fill(bounds, TimelinePalette.bgGutter)
        ctx.fill(CGRect(x: bounds.width - k, y: 0, width: k, height: bounds.height), TimelinePalette.divStrong)

        guard geometry.keyWidth > 0, range.low <= range.high else { return }

        let whiteColour = isDimmed ? TimelinePalette.keyWhiteDimmed : TimelinePalette.keyWhite
        let blackColour = isDimmed ? TimelinePalette.keyBlackDimmed : TimelinePalette.keyBlack
        let labelColour = isDimmed ? TimelinePalette.keyLabelDimmed : TimelinePalette.keyLabel
        let font = TimelineFonts.scaleLabel(k)

        // White keys first, then the black ones over them, as `KeyboardComponentBase::paint` does.
        for note in range.low...range.high where !KeyboardLayout.isBlack(note) {
            let area = geometry.keyRect(note)

            guard area.intersects(dirtyRect) else { continue }

            // A 1 px gap along the bottom and right edges, which is what separates one key from the
            // next: the design has no key outlines, so the background showing through is the divider.
            ctx.fill(CGRect(x: area.minX, y: area.minY, width: area.width - k, height: area.height - k), whiteColour)

            if note % 12 == 0 {
                let label = CGRect(x: area.minX + geometry.blackNoteLength * k, y: area.minY,
                                   width: area.width - geometry.blackNoteLength * k - 5 * k, height: area.height)

                TimelineText.draw("C\(note / 12 - 1)", font: font, colour: labelColour, in: label,
                                  anchor: .centredRight, context: ctx)
            }
        }

        for note in range.low...range.high where KeyboardLayout.isBlack(note) {
            let area = geometry.keyRect(note)

            guard area.intersects(dirtyRect) else { continue }

            ctx.fill(CGRect(x: area.minX, y: area.minY, width: area.width, height: area.height - k), blackColour)
        }
    }

    override func scrollWheel(with event: NSEvent) {
        onWheel?(event)
    }
}
