import AppKit
import CoreText
import NeuralSheetCore
import SwiftUI

/// The palette as CoreGraphics colours, resolved once from `Theme` so the AppKit views paint the
/// same sRGB values the SwiftUI chrome does.
enum TimelinePalette {
    static let bgRoot = cg(Theme.bgRoot)
    static let bgPanel = cg(Theme.bgPanel)
    static let bgGutter = cg(Theme.bgGutter)
    static let divStrong = cg(Theme.divStrong)
    static let divSoft = cg(Theme.divSoft)
    static let divTick = cg(Theme.divTick)
    static let divOctave = cg(Theme.divOctave)
    static let textBright = cg(Theme.textBright)
    static let textFaint = cg(Theme.textFaint)
    static let textScale = cg(Theme.textScale)
    static let accentWashWave = cg(Theme.accentWashWave)
    static let accentWashRoll = cg(Theme.accentWashRoll)
    static let accentWashEdge = cg(Theme.accentWashEdge)
    static let wavePlayed = cg(Theme.wavePlayed)
    static let waveCentreLine = cg(Theme.waveCentreLine)
    static let keyWhite = cg(Theme.keyWhite)
    static let keyBlack = cg(Theme.keyBlack)
    static let keyLabel = cg(Theme.keyLabel)
    static let laneBlack = cg(Theme.laneBlack)
    static let laneWhite = cg(Theme.laneWhite)
    static let noteOnsetEdge = cg(Theme.noteOnsetEdge)
    static let faderTrack = cg(Theme.faderTrack)
    static let ctaBorder = cg(Theme.ctaBorder)
    static let ctaFill = cg(Theme.ctaFill)
    static let dropZoneBorder = cg(Theme.dropZoneBorder)
    static let dropZoneFill = cg(Theme.dropZoneFill)

    /// `Keyboard::_keyColour` while dimmed: the key colour blended 40 % over `bgGutter`.
    static let keyWhiteDimmed = tween(Theme.bgGutter, toward: Theme.keyWhite, proportion: 0.4)
    static let keyBlackDimmed = tween(Theme.bgGutter, toward: Theme.keyBlack, proportion: 0.4)
    static let keyLabelDimmed = tween(Theme.bgGutter, toward: Theme.keyLabel, proportion: 0.4)

    /// `PianoRoll::_drawLanes` while there are no notes: the lanes at 55 %.
    static let laneWhiteEmpty = cg(Theme.laneWhite, alpha: 0.55)
    static let laneBlackEmpty = cg(Theme.laneBlack, alpha: 0.55)
    static let divOctaveEmpty = cg(Theme.divOctave, alpha: 0.55)

    /// `nn::colours::bgRoot.withAlpha(0.75f)`, the unfinished stretch of a running transcription.
    static let frontierShade = cg(Theme.bgRoot, alpha: 0.75)

    /// The Edit tab's finest grid line (design §6.5): `divSoft` at half strength, under the beats.
    static let gridDivision = cg(Theme.divSoft, alpha: 0.5)

    static func cg(_ colour: Color, alpha: Double? = nil) -> CGColor {
        let rgba = colour.rgba

        return CGColor(srgbRed: rgba.red, green: rgba.green, blue: rgba.blue, alpha: alpha ?? rgba.alpha)
    }

    static func cg(_ rgba: NeuralSheetCore.RGBA, alpha: Double) -> CGColor {
        CGColor(srgbRed: rgba.r, green: rgba.g, blue: rgba.b, alpha: alpha)
    }

    /// `juce::Colour::interpolatedWith`, byte for byte: each channel moves by
    /// `floor((to − from) × round(p × 255) / 256)`, which is what `PixelARGB::tween` computes.
    private static func tween(_ from: Color, toward to: Color, proportion: Double) -> CGColor {
        let a = from.rgba
        let b = to.rgba
        let amount = (proportion * 255).rounded()

        func channel(_ x: Double, _ y: Double) -> Double {
            let from = (x * 255).rounded()
            let to = (y * 255).rounded()

            return (from + ((to - from) * amount / 256).rounded(.down)) / 255
        }

        return CGColor(srgbRed: channel(a.red, b.red), green: channel(a.green, b.green),
                       blue: channel(a.blue, b.blue), alpha: 1)
    }
}

/// The two faces the timeline draws with (`nn::fonts::meta` and `scaleLabel`), as CoreText fonts
/// at a UI scale.
enum TimelineFonts {
    static func meta(_ scale: CGFloat) -> CTFont {
        font(Fonts.Name.monoRegular, size: Fonts.Size.meta * scale)
    }

    static func scaleLabel(_ scale: CGFloat) -> CTFont {
        font(Fonts.Name.monoRegular, size: Fonts.Size.scaleLabel * scale)
    }

    private static func font(_ name: String, size: CGFloat) -> CTFont {
        if let font = NSFont(name: name, size: size) {
            return font
        }

        return NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
    }
}

/// How a label sits in its rectangle, the three `juce::Justification`s the timeline uses.
enum TextAnchor {
    case topLeft
    case centredLeft
    case centredRight
    case centred
}

/// `juce::Graphics::drawText` and `nn::drawTrackedText`, over CoreText.
///
/// JUCE places a line by its font box — ascent above the baseline, descent below — and centres
/// that box, not the glyphs' ink, in the rectangle. Tracking is added between glyphs as a fraction
/// of the em, and the justification sees the tracked width.
enum TimelineText {
    /// Draws `text` into a flipped (y down) context.
    static func draw(_ text: String,
                     font: CTFont,
                     colour: CGColor,
                     in rect: CGRect,
                     anchor: TextAnchor,
                     tracking: CGFloat = 0,
                     context: CGContext) {
        guard !text.isEmpty else { return }

        let line = makeLine(text, font: font, colour: colour, tracking: tracking)
        let width = trackedWidth(of: line, tracking: tracking)
        let ascent = CTFontGetAscent(font)
        let descent = CTFontGetDescent(font)

        let x: CGFloat
        switch anchor {
        case .topLeft, .centredLeft: x = rect.minX
        case .centredRight: x = rect.maxX - width
        case .centred: x = rect.midX - width / 2
        }

        let baseline: CGFloat
        switch anchor {
        case .topLeft: baseline = rect.minY + ascent
        case .centredLeft, .centredRight, .centred: baseline = rect.midY - (ascent + descent) / 2 + ascent
        }

        context.saveGState()
        context.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
        context.textPosition = CGPoint(x: x, y: baseline)
        CTLineDraw(line, context)
        context.restoreGState()
    }

    /// The width a label takes, tracking included.
    static func width(_ text: String, font: CTFont, tracking: CGFloat = 0) -> CGFloat {
        let line = makeLine(text, font: font, colour: TimelinePalette.textBright, tracking: tracking)

        return trackedWidth(of: line, tracking: tracking)
    }

    /// The typographic width less the kern CoreText adds after the last glyph, so the result is
    /// `natural + (n − 1) × tracking`, as `nn::trackedTextWidth` has it.
    private static func trackedWidth(of line: CTLine, tracking: CGFloat) -> CGFloat {
        let width = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))

        return tracking != 0 ? width - tracking : width
    }

    private static func makeLine(_ text: String, font: CTFont, colour: CGColor, tracking: CGFloat) -> CTLine {
        var attributes: [NSAttributedString.Key: Any] = [
            kCTFontAttributeName as NSAttributedString.Key: font,
            kCTForegroundColorAttributeName as NSAttributedString.Key: colour,
        ]

        // Tracking in JUCE is `em × pointSize` between glyphs; CoreText's kern is the same thing,
        // applied after every glyph including the last, which `trackedWidth` drops again.
        if tracking != 0 {
            attributes[kCTKernAttributeName as NSAttributedString.Key] = tracking
        }

        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes))

        return line
    }
}

/// Small CoreGraphics conveniences shared by the timeline views.
extension CGContext {
    func fill(_ rect: CGRect, _ colour: CGColor) {
        setFillColor(colour)
        fill(rect)
    }

    /// A rounded rectangle whose corner never exceeds half a side, as `juce::Path::addRoundedRectangle`
    /// clamps it.
    func fillRoundedRect(_ rect: CGRect, corner: CGFloat, _ colour: CGColor) {
        let radius = min(corner, rect.width / 2, rect.height / 2)

        guard radius > 0, rect.width > 0, rect.height > 0 else {
            fill(rect, colour)
            return
        }

        setFillColor(colour)
        addPath(CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil))
        fillPath()
    }
}
