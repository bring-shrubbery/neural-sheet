#if os(macOS)
import AppKit
#else
import UIKit
#endif
import CoreText
import NeuralSheetCore
import SwiftUI

/// The palette as CoreGraphics colours, resolved from `Theme` so the AppKit views paint the same
/// sRGB values the SwiftUI chrome does. One set per appearance and contrast, made once each, so a
/// draw loop picks a colour rather than converting a `Color` per lane; which set is in force
/// follows ``ThemeAppearance`` and ``Accommodations`` (native chrome design §2, a11y design §2).
enum TimelinePalette {
    /// Every colour the timeline draws with, for one appearance and contrast.
    struct Resolved {
        let bgRoot, bgPanel, bgGutter, textBright, textPrimary: CGColor
        let divStrong, divSoft, divTick, divOctave, textFaint, textScale, keyLabel, dropZoneBorder: CGColor
        let accentWashWave, accentWashRoll, accentWashEdge, wavePlayed, waveCentreLine: CGColor
        let keyWhite, keyBlack, laneBlack, laneWhite, noteOnsetEdge, faderTrack: CGColor
        let ctaBorder, ctaFill, dropZoneFill: CGColor
        let keyWhiteDimmed, keyBlackDimmed, keyLabelDimmed: CGColor
        let laneWhiteEmpty, laneTonic, laneBlackEmpty, divOctaveEmpty, frontierShade, gridDivision: CGColor
        let marqueeBorder, marqueeFill, tempoFlag, tempoStem, tempoLabel: CGColor
        let markerFlag, markerStem, markerLabel, rangeFill, rangeEdge, rangeProgress: CGColor

        init(_ p: Theme.Palette, _ c: Theme.ContrastPalette) {
            bgRoot = cg(p.bgRoot)
            bgPanel = cg(p.bgPanel)
            bgGutter = cg(p.bgGutter)
            textBright = cg(p.textBright)
            // Design §6.5: a selected note's outline.
            textPrimary = cg(p.textPrimary)

            divStrong = cg(c.divStrong)
            divSoft = cg(c.divSoft)
            divTick = cg(c.divTick)
            divOctave = cg(c.divOctave)
            textFaint = cg(c.textFaint)
            textScale = cg(c.textScale)
            keyLabel = cg(c.keyLabel)
            dropZoneBorder = cg(c.dropZoneBorder)

            accentWashWave = cg(p.accent, alpha: 0.045)
            accentWashRoll = cg(p.accent, alpha: 0.03)
            accentWashEdge = cg(p.accent, alpha: 0.14)
            wavePlayed = cg(p.wavePlayed)
            waveCentreLine = cg(p.waveCentreLine)
            keyWhite = cg(p.keyWhite)
            keyBlack = cg(p.keyBlack)
            laneBlack = cg(p.laneBlack)
            laneWhite = cg(p.laneWhite)
            noteOnsetEdge = cg(p.noteOnsetEdge)
            faderTrack = cg(p.faderTrack)
            ctaBorder = cg(p.accent)
            ctaFill = cg(p.accent, alpha: 0.11)
            dropZoneFill = cg(p.accent, alpha: 0.015)

            // `Keyboard::_keyColour` while dimmed: the key colour blended 40 % over `bgGutter`.
            keyWhiteDimmed = tween(p.bgGutter, toward: p.keyWhite, proportion: 0.4)
            keyBlackDimmed = tween(p.bgGutter, toward: p.keyBlack, proportion: 0.4)
            keyLabelDimmed = tween(p.bgGutter, toward: c.keyLabel, proportion: 0.4)

            // `PianoRoll::_drawLanes` while there are no notes: the lanes at 55 %.
            laneWhiteEmpty = cg(p.laneWhite, alpha: 0.55)
            // Key design §5: the tonic's lanes, a wash over the light lane.
            laneTonic = cg(p.accent, alpha: 0.10)
            laneBlackEmpty = cg(p.laneBlack, alpha: 0.55)
            divOctaveEmpty = cg(c.divOctave, alpha: 0.55)
            // `nn::colours::bgRoot.withAlpha(0.75f)`, the unfinished stretch of a running
            // transcription.
            frontierShade = cg(p.bgRoot, alpha: 0.75)
            // The Edit tab's finest grid line (design §6.5): `divSoft` at half strength, under the
            // beats.
            gridDivision = cg(c.divSoft, alpha: 0.5)

            // Design §6.5: the marquee in the accent.
            marqueeBorder = cg(p.accent)
            marqueeFill = cg(p.accent, alpha: 0.12)

            // Tempo map design §4: a tempo change's flag on the ruler, the accent over the panel,
            // its stem and its label.
            tempoFlag = tween(p.bgPanel, toward: p.accent, proportion: 0.3)
            tempoStem = cg(p.accent)
            tempoLabel = cg(p.accentText)

            // Markers and lyrics design §2: a section marker's flag along the ruler's lower half,
            // in the accent like the tempo flags but lighter, so the two rows read apart.
            markerFlag = cg(p.accent, alpha: 0.22)
            markerStem = cg(p.accent)
            markerLabel = cg(p.textBright)

            // Region design §6.3: the marked range, its edges, and the fill that grows with a run.
            rangeFill = cg(p.accent, alpha: 0.10)
            rangeEdge = cg(p.accent, alpha: 0.6)
            rangeProgress = cg(p.accent, alpha: 0.22)
        }
    }

    private static let darkStandard = Resolved(.dark, .darkStandard)
    private static let darkHigh = Resolved(.dark, .darkHigh)
    private static let lightStandard = Resolved(.light, .lightStandard)
    private static let lightHigh = Resolved(.light, .lightHigh)

    /// The set in force.
    static var current: Resolved {
        switch (ThemeAppearance.shared.isDark, Accommodations.shared.increaseContrast) {
        case (true, false): darkStandard
        case (true, true): darkHigh
        case (false, false): lightStandard
        case (false, true): lightHigh
        }
    }

    static var bgRoot: CGColor { current.bgRoot }
    static var bgPanel: CGColor { current.bgPanel }
    static var bgGutter: CGColor { current.bgGutter }
    static var divStrong: CGColor { current.divStrong }
    static var divSoft: CGColor { current.divSoft }
    static var divTick: CGColor { current.divTick }
    static var divOctave: CGColor { current.divOctave }
    static var textBright: CGColor { current.textBright }
    static var textFaint: CGColor { current.textFaint }
    static var textScale: CGColor { current.textScale }
    static var accentWashWave: CGColor { current.accentWashWave }
    static var accentWashRoll: CGColor { current.accentWashRoll }
    static var accentWashEdge: CGColor { current.accentWashEdge }
    static var wavePlayed: CGColor { current.wavePlayed }
    static var waveCentreLine: CGColor { current.waveCentreLine }
    static var keyWhite: CGColor { current.keyWhite }
    static var keyBlack: CGColor { current.keyBlack }
    static var keyLabel: CGColor { current.keyLabel }
    static var laneBlack: CGColor { current.laneBlack }
    static var laneWhite: CGColor { current.laneWhite }
    static var noteOnsetEdge: CGColor { current.noteOnsetEdge }
    static var faderTrack: CGColor { current.faderTrack }
    static var ctaBorder: CGColor { current.ctaBorder }
    static var ctaFill: CGColor { current.ctaFill }
    static var dropZoneBorder: CGColor { current.dropZoneBorder }
    static var dropZoneFill: CGColor { current.dropZoneFill }
    static var keyWhiteDimmed: CGColor { current.keyWhiteDimmed }
    static var keyBlackDimmed: CGColor { current.keyBlackDimmed }
    static var keyLabelDimmed: CGColor { current.keyLabelDimmed }
    static var laneWhiteEmpty: CGColor { current.laneWhiteEmpty }
    static var laneTonic: CGColor { current.laneTonic }
    static var laneBlackEmpty: CGColor { current.laneBlackEmpty }
    static var divOctaveEmpty: CGColor { current.divOctaveEmpty }
    static var frontierShade: CGColor { current.frontierShade }
    static var gridDivision: CGColor { current.gridDivision }
    static var textPrimary: CGColor { current.textPrimary }
    static var marqueeBorder: CGColor { current.marqueeBorder }
    static var marqueeFill: CGColor { current.marqueeFill }
    static var tempoFlag: CGColor { current.tempoFlag }
    static var tempoStem: CGColor { current.tempoStem }
    static var tempoLabel: CGColor { current.tempoLabel }
    static var markerFlag: CGColor { current.markerFlag }
    static var markerStem: CGColor { current.markerStem }
    static var markerLabel: CGColor { current.markerLabel }
    static var rangeFill: CGColor { current.rangeFill }
    static var rangeEdge: CGColor { current.rangeEdge }
    static var rangeProgress: CGColor { current.rangeProgress }

    static func cg(_ colour: Color, alpha: Double? = nil) -> CGColor {
        let rgba = colour.rgba

        return CGColor(srgbRed: rgba.red, green: rgba.green, blue: rgba.blue, alpha: alpha ?? rgba.alpha)
    }

    static func cg(_ rgba: NeuralSheetCore.RGBA, alpha: Double) -> CGColor {
        CGColor(srgbRed: rgba.r, green: rgba.g, blue: rgba.b, alpha: alpha)
    }

    // MARK: - Instrument colours

    /// An instrument's colour as the appearance draws it (native chrome design §3): itself on the
    /// dark side; on the light side the same hue and saturation with its HSL lightness held to
    /// ``lightMaxLightness``, so a pale green or lilac still reads on a white lane.
    static func instrument(_ rgba: NeuralSheetCore.RGBA, dark: Bool) -> NeuralSheetCore.RGBA {
        guard !dark else { return rgba }

        let high = max(rgba.r, rgba.g, rgba.b)
        let low = min(rgba.r, rgba.g, rgba.b)
        let lightness = (high + low) / 2

        guard lightness > lightMaxLightness, high > low else { return rgba }

        // Scaling each channel's distance from the grey of the same lightness keeps the hue
        // and the HSL saturation; the grey moves to the new lightness.
        let saturation = (high - low) / (1 - abs(2 * lightness - 1))
        let newSpan = saturation * (1 - abs(2 * lightMaxLightness - 1))
        let scale = newSpan / (high - low)

        func channel(_ value: Double) -> Double {
            min(1, max(0, lightMaxLightness + (value - lightness) * scale))
        }

        return NeuralSheetCore.RGBA(r: channel(rgba.r), g: channel(rgba.g), b: channel(rgba.b), a: rgba.a)
    }

    /// The light side's ceiling on an instrument colour's lightness.
    static let lightMaxLightness = 0.5

    /// An instrument's colour in the appearance the app is drawn in.
    static func instrument(_ rgba: NeuralSheetCore.RGBA) -> NeuralSheetCore.RGBA {
        instrument(rgba, dark: ThemeAppearance.shared.isDark)
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

    /// The chord lane's symbols (chord symbols design §2): the ruler's face, a size up.
    static func chord(_ scale: CGFloat) -> CTFont {
        font(Fonts.Name.monoRegular, size: (Fonts.Size.meta + 1) * scale)
    }

    static func scaleLabel(_ scale: CGFloat) -> CTFont {
        font(Fonts.Name.monoRegular, size: Fonts.Size.scaleLabel * scale)
    }

    private static func font(_ name: String, size: CGFloat) -> CTFont {
        #if os(macOS)
        if let font = NSFont(name: name, size: size) {
            return font
        }

        return NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
        #else
        if let font = UIFont(name: name, size: size) {
            return font
        }

        return UIFont.monospacedSystemFont(ofSize: size, weight: .regular)
        #endif
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

extension Color {
    /// An instrument's colour as the appearance the app is drawn in shows it (native chrome
    /// design §3): a chip, a fader's fill, a menu row's dot.
    init(instrument rgba: NeuralSheetCore.RGBA) {
        let drawn = TimelinePalette.instrument(rgba)

        self.init(.sRGB, red: drawn.r, green: drawn.g, blue: drawn.b, opacity: drawn.a)
    }
}
