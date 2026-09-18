import AppKit
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
        guard let resolved = NSColor(self).usingColorSpace(.sRGB) else {
            return RGBA(red: 0, green: 0, blue: 0, alpha: 0)
        }

        return RGBA(red: Double(resolved.redComponent),
                    green: Double(resolved.greenComponent),
                    blue: Double(resolved.blueComponent),
                    alpha: Double(resolved.alphaComponent))
    }

    func darker(_ amount: Double) -> Color {
        Color(rgba.darker(amount))
    }

    func brighter(_ amount: Double) -> Color {
        Color(rgba.brighter(amount))
    }
}

/// The palette and the shared interaction rules, ported from `nn::colours` and `nn::surfaceFor` /
/// `nn::foregroundFor`. Every name is the C++ name; every value is the C++ value.
///
/// There are no disabled variants here on purpose: a disabled control is its enabled self drawn at
/// `disabledAlpha`.
enum Theme {
    // MARK: - Surfaces

    static let windowBorder = Color(hex: 0x26282E)
    static let bgRoot = Color(hex: 0x131417)
    static let bgTopBar = Color(hex: 0x17181C)
    static let bgSidebar = Color(hex: 0x161719)
    static let bgPanel = Color(hex: 0x15161A)
    static let bgGutter = Color(hex: 0x16171A)
    static let bgControl = Color(hex: 0x1C1E23)
    static let bgControlAlt = Color(hex: 0x1B1D21)
    static let bgControlSubtle = Color(hex: 0x1F2126)
    static let bgControlActive = Color(hex: 0x22242A)
    static let bgMuteActive = Color(hex: 0x3A2F22)

    // MARK: - Dividers

    static let divStrong = Color(hex: 0x24262C)
    static let divSoft = Color(hex: 0x202227)
    static let divRow = Color(hex: 0x1E2024)
    static let divTick = Color(hex: 0x22242A)
    static let divOctave = Color(hex: 0x232529)

    // MARK: - Text

    static let textBright = Color(hex: 0xF2F4F7)
    static let textPrimary = Color(hex: 0xE7E9EC)
    static let textStrong = Color(hex: 0xDCDFE4)
    static let textFile = Color(hex: 0xD7DADE)
    static let textButton = Color(hex: 0xC2C6CC)
    static let textIcon = Color(hex: 0x9BA1AB)
    static let textIconSoft = Color(hex: 0x8E939C)
    static let textLabel = Color(hex: 0x7A808A)
    static let textMuted = Color(hex: 0x797F88)
    static let textDim = Color(hex: 0x6B7078)
    static let textFaint = Color(hex: 0x5D626B)
    static let textFainter = Color(hex: 0x585D65)
    static let textFaintest = Color(hex: 0x565B63)
    static let textScale = Color(hex: 0x4E535B)
    static let textSeparator = Color(hex: 0x33363C)

    // MARK: - Accent

    static let accent = Color(hex: 0x6E9BFF)
    static let accentText = Color(hex: 0xA8C2FF)
    static let accentFillActive = Color(hex: 0x6E9BFF, alpha: 0.14)
    static let accentFillButton = Color(hex: 0x6E9BFF, alpha: 0.09)
    static let accentWashWave = Color(hex: 0x6E9BFF, alpha: 0.045)
    static let accentWashRoll = Color(hex: 0x6E9BFF, alpha: 0.03)
    static let accentWashEdge = Color(hex: 0x6E9BFF, alpha: 0.14)

    // MARK: - Status

    static let warn = Color(hex: 0xF2A33C)
    static let rec = Color(hex: 0xFF6B8A)
    static let recIdle = Color(hex: 0x7A3B44)

    // MARK: - Level meters

    static let meterLow = Color(hex: 0x4F7A52)
    static let meterMid = Color(hex: 0x8EC98C)
    static let meterHot = warn
    static let meterUnlitStrip = bgControlActive
    static let meterUnlitMaster = bgControlSubtle

    // MARK: - Waveform

    static let wavePlayed = Color(hex: 0x7D8797)
    static let waveUnplayed = Color(hex: 0x3A3F47)
    static let waveCentreLine = Color.white.opacity(0.05)

    // MARK: - Piano roll

    static let keyWhite = Color(hex: 0xE2E4E8)
    static let keyBlack = Color(hex: 0x0E0F11)
    static let keyLabel = Color(hex: 0x7C818A)
    static let laneBlack = Color(hex: 0x141519)
    static let laneWhite = Color(hex: 0x191A1E)
    static let noteOnsetEdge = Color.white.opacity(0.35)

    // MARK: - Faders

    static let faderTrack = Color(hex: 0x26282E)
    static let faderTrackTop = Color(hex: 0x2B2E35)
    static let faderThumb = Color(hex: 0xE7E9EC)
    static let faderThumbMuted = Color(hex: 0x5A5F67)
    static let faderFillMuted = Color(hex: 0x3A3D44)
    static let volumeFill = Color(hex: 0x8E939C)

    // MARK: - Popups

    static let popupBg = Color(hex: 0x1B1D21)
    static let popupBorder = Color(hex: 0x2E3138)
    static let popupFooterBg = Color(hex: 0x191A1E)
    static let popupRowHover = Color(hex: 0x22242A)
    static let popupTitle = Color(hex: 0x6B7078)
    static let popupItem = Color(hex: 0xA8ADB5)
    static let popupItemTicked = Color(hex: 0xE7E9EC)
    static let checkboxBorder = Color(hex: 0x3A3D44)
    static let checkboxTick = Color(hex: 0x12131A)
    static let popupShadow = Color.black.opacity(0.55)

    // MARK: - Empty states

    static let ctaBorder = accent
    static let ctaText = accentText
    static let dropZoneBorder = Color(hex: 0x2B2E35)
    static let ctaFill = Color(hex: 0x6E9BFF, alpha: 0.11)
    static let dropZoneFill = Color(hex: 0x6E9BFF, alpha: 0.015)

    // MARK: - Transcription progress

    static let progressTrack = Color(hex: 0x26282E)
    static let progressFill = accent
    static let progressText = accentText

    // MARK: - Vertical zoom slider

    static let zoomIcon = Color(hex: 0x585D65)
    static let zoomTrack = Color(hex: 0x26282E)
    static let zoomFill = Color(hex: 0x6B7078)
    static let zoomThumb = Color(hex: 0xC2C6CC)

    // MARK: - Instrument-derived chips

    /// Sidebar chip fill, derived from the instrument colour.
    static func chipFill(_ colour: Color) -> Color {
        colour.opacity(0.13)
    }

    /// Sidebar chip border, derived from the instrument colour.
    static func chipBorder(_ colour: Color) -> Color {
        colour.opacity(0.25)
    }

    static let soloRowTint = Color(hex: 0xFF6B8A, alpha: 0.05)
    static let soloButtonBg = Color(hex: 0xFF6B8A, alpha: 0.18)

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
