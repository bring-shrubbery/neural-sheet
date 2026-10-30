#if os(macOS)
import AppKit
#else
import UIKit
#endif
import SwiftUI

/// A plain sRGB colour, kept alongside `Color` so the palette can be darkened and brightened with
/// the same arithmetic JUCE used. `Color` has no readable components, and rounding a colour through
/// a different formula is how a hover surface stops matching the one in the original.
nonisolated struct RGBA: Hashable, Sendable {
    var red: Double
    var green: Double
    var blue: Double
    var alpha: Double

    init(red: Double, green: Double, blue: Double, alpha: Double = 1) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }

    /// `0xRRGGBB`, as the palette is written in `NnLook.h`.
    init(hex: UInt32, alpha: Double = 1) {
        self.init(red: Double((hex >> 16) & 0xFF) / 255.0,
                  green: Double((hex >> 8) & 0xFF) / 255.0,
                  blue: Double(hex & 0xFF) / 255.0,
                  alpha: alpha)
    }

    func withAlpha(_ newAlpha: Double) -> RGBA {
        RGBA(red: red, green: green, blue: blue, alpha: newAlpha)
    }

    /// `juce::Colour::darker`, byte for byte: the channels are scaled by `1 / (1 + amount)` and
    /// truncated to 8 bits, which is what the original's pressed surfaces are.
    func darker(_ amount: Double) -> RGBA {
        let factor = 1.0 / (1.0 + max(0.0, amount))

        return RGBA(red: RGBA.quantised(factor * red * 255.0),
                    green: RGBA.quantised(factor * green * 255.0),
                    blue: RGBA.quantised(factor * blue * 255.0),
                    alpha: alpha)
    }

    /// `juce::Colour::brighter`: the same scaling applied to the distance from white.
    func brighter(_ amount: Double) -> RGBA {
        let factor = 1.0 / (1.0 + max(0.0, amount))

        return RGBA(red: RGBA.quantised(255.0 - factor * (255.0 - red * 255.0)),
                    green: RGBA.quantised(255.0 - factor * (255.0 - green * 255.0)),
                    blue: RGBA.quantised(255.0 - factor * (255.0 - blue * 255.0)),
                    alpha: alpha)
    }

    /// Truncation, not rounding: `(uint8) value` in C++ drops the fraction.
    private static func quantised(_ value: Double) -> Double {
        min(255.0, max(0.0, value.rounded(.towardZero))) / 255.0
    }
}

extension Color {
    /// `0xRRGGBB`, as the palette is written in `NnLook.h`.
    init(hex: UInt32, alpha: Double = 1) {
        self.init(RGBA(hex: hex, alpha: alpha))
    }

    init(_ rgba: RGBA) {
        self.init(.sRGB, red: rgba.red, green: rgba.green, blue: rgba.blue, opacity: rgba.alpha)
    }

    /// The sRGB components behind this colour, so the interaction rules can do real arithmetic.
    var rgba: RGBA {
        #if os(macOS)
        guard let resolved = NSColor(self).usingColorSpace(.sRGB) else {
            return RGBA(red: 0, green: 0, blue: 0, alpha: 0)
        }

        return RGBA(red: Double(resolved.redComponent),
                    green: Double(resolved.greenComponent),
                    blue: Double(resolved.blueComponent),
                    alpha: Double(resolved.alphaComponent))
        #else
        // The iPhone and iPad app (iOS app design §2): the same sRGB components through UIKit.
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0

        guard UIColor(self).getRed(&red, green: &green, blue: &blue, alpha: &alpha) else {
            return RGBA(red: 0, green: 0, blue: 0, alpha: 0)
        }

        return RGBA(red: Double(red), green: Double(green), blue: Double(blue), alpha: Double(alpha))
        #endif
    }

    func darker(_ amount: Double) -> Color {
        Color(rgba.darker(amount))
    }

    func brighter(_ amount: Double) -> Color {
        Color(rgba.brighter(amount))
    }
}

/// The palette and the shared interaction rules, ported from `nn::colours` and `nn::surfaceFor` /
/// `nn::foregroundFor`. Every name is the C++ name; the dark values are the C++ values, and each
/// has a light twin (native chrome design §3) in `Theme+Palette.swift`. Each colour is read
/// through `ThemeAppearance`, so a SwiftUI body using one is drawn again when the appearance flips.
///
/// There are no disabled variants here on purpose: a disabled control is its enabled self drawn at
/// `disabledAlpha`.
enum Theme {
    // MARK: - Surfaces

    static var windowBorder: Color { palette.windowBorder }
    static var bgRoot: Color { palette.bgRoot }
    static var bgTopBar: Color { palette.bgTopBar }
    static var bgSidebar: Color { palette.bgSidebar }
    static var bgPanel: Color { palette.bgPanel }
    static var bgGutter: Color { palette.bgGutter }
    static var bgControl: Color { palette.bgControl }
    static var bgControlAlt: Color { palette.bgControlAlt }
    static var bgControlSubtle: Color { palette.bgControlSubtle }
    static var bgControlActive: Color { palette.bgControlActive }
    static var bgMuteActive: Color { palette.bgMuteActive }

    // MARK: - Dividers

    // divStrong, divSoft, divRow, divTick, divOctave: `Theme+Accommodations.swift`, where
    // Increase Contrast strengthens them (a11y design §2).

    // MARK: - Text

    // textButton, textIcon, textIconSoft, textLabel, textMuted, textDim, textFaint, textFainter,
    // textFaintest, textScale and textSeparator are in `Theme+Accommodations.swift` too.

    static var textBright: Color { palette.textBright }
    static var textPrimary: Color { palette.textPrimary }
    static var textStrong: Color { palette.textStrong }
    static var textFile: Color { palette.textFile }

    // MARK: - Accent

    static var accent: Color { palette.accent }
    static var accentText: Color { palette.accentText }
    static var accentFillActive: Color { accent.opacity(0.14) }
    static var accentFillButton: Color { accent.opacity(0.09) }
    static var accentWashWave: Color { accent.opacity(0.045) }
    static var accentWashRoll: Color { accent.opacity(0.03) }
    static var accentWashEdge: Color { accent.opacity(0.14) }

    // MARK: - Status

    static var warn: Color { palette.warn }
    static var rec: Color { palette.rec }
    static var recIdle: Color { palette.recIdle }

    // MARK: - Level meters

    static var meterLow: Color { palette.meterLow }
    static var meterMid: Color { palette.meterMid }
    static var meterHot: Color { warn }
    static var meterUnlitStrip: Color { bgControlActive }
    static var meterUnlitMaster: Color { bgControlSubtle }

    // MARK: - Waveform

    static var wavePlayed: Color { palette.wavePlayed }
    static var waveUnplayed: Color { palette.waveUnplayed }
    static var waveCentreLine: Color { palette.waveCentreLine }

    // MARK: - Piano roll

    static var keyWhite: Color { palette.keyWhite }
    static var keyBlack: Color { palette.keyBlack }
    static var laneBlack: Color { palette.laneBlack }
    static var laneWhite: Color { palette.laneWhite }
    static var noteOnsetEdge: Color { palette.noteOnsetEdge }

    // MARK: - Faders

    static var faderTrack: Color { palette.faderTrack }
    static var faderTrackTop: Color { palette.faderTrackTop }
    static var faderThumb: Color { palette.faderThumb }
    static var faderThumbMuted: Color { palette.faderThumbMuted }
    static var faderFillMuted: Color { palette.faderFillMuted }
    static var volumeFill: Color { palette.volumeFill }

    // MARK: - Popups

    static var popupBg: Color { palette.popupBg }
    static var popupFooterBg: Color { palette.popupFooterBg }
    static var popupRowHover: Color { palette.popupRowHover }
    static var popupItemTicked: Color { palette.popupItemTicked }
    static var checkboxTick: Color { palette.checkboxTick }
    static var popupShadow: Color { palette.popupShadow }

    // MARK: - Empty states

    static var ctaBorder: Color { accent }
    static var ctaText: Color { accentText }
    static var ctaFill: Color { accent.opacity(0.11) }
    static var dropZoneFill: Color { accent.opacity(0.015) }

    // MARK: - Transcription progress

    static var progressTrack: Color { palette.progressTrack }
    static var progressFill: Color { accent }
    static var progressText: Color { accentText }

    // MARK: - Vertical zoom slider

    static var zoomTrack: Color { palette.zoomTrack }
    static var zoomFill: Color { palette.zoomFill }
    static var zoomThumb: Color { palette.zoomThumb }

    // MARK: - Instrument-derived chips

    /// Sidebar chip fill, derived from the instrument colour.
    static func chipFill(_ colour: Color) -> Color {
        colour.opacity(0.13)
    }

    /// Sidebar chip border, derived from the instrument colour; at full alpha under Increase
    /// Contrast (a11y design §2).
    static func chipBorder(_ colour: Color) -> Color {
        colour.opacity(Accommodations.shared.increaseContrast ? 1 : 0.25)
    }

    static var soloRowTint: Color { rec.opacity(0.05) }
    static var soloButtonBg: Color { rec.opacity(0.18) }

    // MARK: - Global alphas

    /// Painted over the whole control when it is disabled, rather than a second set of colours.
    static let disabledAlpha: Double = 0.38

    /// Painted over a whole instrument strip when the instrument is muted.
    static let mutedAlpha: Double = 0.5

    // MARK: - Interaction states

    /// The background a control paints, given its idle and toggled-on fills (`nn::surfaceFor`).
    ///
    /// Hover lifts an idle control onto the one shared hover surface, which is what makes a
    /// transparent transport button and a filled top-bar pill light up identically. A control that
    /// is already on keeps its fill and brightens its foreground instead.
    static func surface(idle: Color,
                        on: Color,
                        isOn: Bool,
                        isHovered: Bool,
                        isPressed: Bool,
                        isEnabled: Bool) -> Color {
        let surface = isOn ? on : idle

        if !isEnabled {
            return surface
        }

        if isPressed {
            return (isOn ? surface : bgControlSubtle).darker(0.15)
        }

        if isHovered && !isOn {
            return bgControlSubtle
        }

        return surface
    }

    /// The icon / label colour matching `surface` (`nn::foregroundFor`).
    static func foreground(idle: Color, on: Color, isOn: Bool, isHovered: Bool) -> Color {
        let foreground = isOn ? on : idle

        if isHovered && isOn {
            return foreground.brighter(0.12)
        }

        return foreground
    }
}
