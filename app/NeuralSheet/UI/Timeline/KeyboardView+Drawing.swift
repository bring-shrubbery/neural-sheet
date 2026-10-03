import CoreGraphics
import NeuralSheetCore

/// What the key column left of the piano roll draws (`Keyboard`, a `KeyboardComponentBase` facing
/// right), apart from any view: white keys with a 1 px gap on their bottom and right edges, black
/// keys with a 1 px bottom gap, every C labelled, the whole column blended 40 % toward the gutter
/// while dimmed, and the scale's dots under Differentiate Without Colour. ``KeyboardView`` on the
/// Mac and the iPhone and iPad app's keyboard gutter call it (iOS app design §2).
enum KeyboardPainter {
    static func draw(_ ctx: CGContext, in dirtyRect: CGRect, bounds: CGRect, geometry: TimelineGeometry, isDimmed: Bool,
                     key: MusicalKey?) {
        let k = geometry.scale
        let range = geometry.pitchRange

        // `Keyboard::drawKeyboardBackground`.
        ctx.fill(dirtyRect, TimelinePalette.bgGutter)
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

        if let key, Accommodations.shared.differentiateWithoutColour {
            drawScaleDots(ctx, key: key, range: range, geometry: geometry, in: dirtyRect)
        }
    }

    /// A dot in each lane of the scale, in the gutter beside the key names -- on the white key
    /// past the black keys' ends, inside a black key near its tip -- and a ring round the
    /// tonic's (a11y design §2).
    private static func drawScaleDots(_ ctx: CGContext, key: MusicalKey, range: PitchRange, geometry: TimelineGeometry,
                                      in dirtyRect: CGRect) {
        let k = geometry.scale
        let radius = 2 * k

        for note in range.low...range.high where key.contains(pitch: note) {
            let lane = geometry.lane(forPitch: note)
            let black = KeyboardLayout.isBlack(note)
            let x = black ? (geometry.blackNoteLength - 6) * k : (geometry.blackNoteLength + 5) * k
            let centre = CGPoint(x: x, y: lane.y + lane.height / 2)
            let dot = CGRect(x: centre.x - radius, y: centre.y - radius, width: 2 * radius, height: 2 * radius)

            guard dot.intersects(dirtyRect) else { continue }

            let colour = black ? TimelinePalette.keyWhite : TimelinePalette.keyBlack

            if key.isTonic(pitch: note) {
                ctx.setStrokeColor(colour)
                ctx.setLineWidth(k)
                ctx.strokeEllipse(in: dot.insetBy(dx: -k, dy: -k))
            }

            ctx.setFillColor(colour)
            ctx.fillEllipse(in: dot)
        }
    }
}
