import Observation
import SwiftUI

/// Whether the palette is drawn dark or light (native chrome design §2). Dark unless the Mac app
/// says otherwise: the iOS app and the Audio Unit share `Theme` and never set it, so they keep
/// the dark palette they were designed in.
///
/// Observable, so a SwiftUI body that drew with a `Theme` colour is drawn again when it flips;
/// the AppKit views are told by `Accommodations.didChange`, posted by whoever flips it.
@Observable final class ThemeAppearance {
    static let shared = ThemeAppearance()

    /// Assigned only on a change, by the Mac app's `AppearanceTracker`.
    var isDark = true

    private init() {}
}

extension Theme {
    /// Every colour the palette has whatever the accommodations say, for one appearance. The dark
    /// side is `nn::colours` as `NnLook.h` wrote it; the light side gives each the same role on a
    /// white ground (native chrome design §3).
    struct Palette {
        let windowBorder, bgRoot, bgTopBar, bgSidebar, bgPanel, bgGutter: Color
        let bgControl, bgControlAlt, bgControlSubtle, bgControlActive, bgMuteActive: Color
        let textBright, textPrimary, textStrong, textFile: Color
        let accent, accentText: Color
        let warn, rec, recIdle: Color
        let meterLow, meterMid: Color
        let wavePlayed, waveUnplayed, waveCentreLine: Color
        let keyWhite, keyBlack, laneBlack, laneWhite, noteOnsetEdge: Color
        let faderTrack, faderTrackTop, faderThumb, faderThumbMuted, faderFillMuted, volumeFill: Color
        let popupBg, popupFooterBg, popupRowHover, popupItemTicked, checkboxTick, popupShadow: Color
        let progressTrack, zoomTrack, zoomFill, zoomThumb: Color

        static let dark = Palette(
            windowBorder: Color(hex: 0x26282E), bgRoot: Color(hex: 0x131417), bgTopBar: Color(hex: 0x17181C),
            bgSidebar: Color(hex: 0x161719), bgPanel: Color(hex: 0x15161A), bgGutter: Color(hex: 0x16171A),
            bgControl: Color(hex: 0x1C1E23), bgControlAlt: Color(hex: 0x1B1D21), bgControlSubtle: Color(hex: 0x1F2126),
            bgControlActive: Color(hex: 0x22242A), bgMuteActive: Color(hex: 0x3A2F22),
            textBright: Color(hex: 0xF2F4F7), textPrimary: Color(hex: 0xE7E9EC), textStrong: Color(hex: 0xDCDFE4),
            textFile: Color(hex: 0xD7DADE),
            accent: Color(hex: 0x6E9BFF), accentText: Color(hex: 0xA8C2FF),
            warn: Color(hex: 0xF2A33C), rec: Color(hex: 0xFF6B8A), recIdle: Color(hex: 0x7A3B44),
            meterLow: Color(hex: 0x4F7A52), meterMid: Color(hex: 0x8EC98C),
            wavePlayed: Color(hex: 0x7D8797), waveUnplayed: Color(hex: 0x3A3F47), waveCentreLine: Color.white.opacity(0.05),
            keyWhite: Color(hex: 0xE2E4E8), keyBlack: Color(hex: 0x0E0F11), laneBlack: Color(hex: 0x141519),
            laneWhite: Color(hex: 0x191A1E), noteOnsetEdge: Color.white.opacity(0.35),
            faderTrack: Color(hex: 0x26282E), faderTrackTop: Color(hex: 0x2B2E35), faderThumb: Color(hex: 0xE7E9EC),
            faderThumbMuted: Color(hex: 0x5A5F67), faderFillMuted: Color(hex: 0x3A3D44), volumeFill: Color(hex: 0x8E939C),
            popupBg: Color(hex: 0x1B1D21), popupFooterBg: Color(hex: 0x191A1E), popupRowHover: Color(hex: 0x22242A),
            popupItemTicked: Color(hex: 0xE7E9EC), checkboxTick: Color(hex: 0x12131A), popupShadow: Color.black.opacity(0.55),
            progressTrack: Color(hex: 0x26282E), zoomTrack: Color(hex: 0x26282E), zoomFill: Color(hex: 0x6B7078),
            zoomThumb: Color(hex: 0xC2C6CC))

        /// White lanes and panels, the system's greys for the controls, black text at the
        /// system's alphas, and the accent, record and warning colours of the system's light side.
        static let light = Palette(
            windowBorder: Color(hex: 0xD1D1D6), bgRoot: Color(hex: 0xFFFFFF), bgTopBar: Color(hex: 0xF5F5F7),
            bgSidebar: Color(hex: 0xF5F5F7), bgPanel: Color(hex: 0xFAFAFC), bgGutter: Color(hex: 0xF5F5F7),
            bgControl: Color(hex: 0xE8E8ED), bgControlAlt: Color(hex: 0xEBEBF0), bgControlSubtle: Color(hex: 0xE1E1E6),
            bgControlActive: Color(hex: 0xDCDCE1), bgMuteActive: Color(hex: 0xFCE6C6),
            textBright: Color(hex: 0x1D1D1F), textPrimary: Color(hex: 0x1D1D1F), textStrong: Color(hex: 0x242426),
            textFile: Color(hex: 0x2C2C2E),
            accent: Color(hex: 0x007AFF), accentText: Color(hex: 0x0063CC),
            warn: Color(hex: 0xC76A00), rec: Color(hex: 0xE5302A), recIdle: Color(hex: 0xE8A3A6),
            meterLow: Color(hex: 0x7CCB8A), meterMid: Color(hex: 0x2FA84F),
            wavePlayed: Color(hex: 0x636366), waveUnplayed: Color(hex: 0xC7C7CC), waveCentreLine: Color.black.opacity(0.06),
            keyWhite: Color(hex: 0xFFFFFF), keyBlack: Color(hex: 0x2C2C2E), laneBlack: Color(hex: 0xF0F0F3),
            laneWhite: Color(hex: 0xFFFFFF), noteOnsetEdge: Color.white.opacity(0.45),
            faderTrack: Color(hex: 0xD1D1D6), faderTrackTop: Color(hex: 0xD1D1D6), faderThumb: Color(hex: 0x3A3A3C),
            faderThumbMuted: Color(hex: 0xAEAEB2), faderFillMuted: Color(hex: 0xC7C7CC), volumeFill: Color(hex: 0x8E8E93),
            popupBg: Color(hex: 0xFFFFFF), popupFooterBg: Color(hex: 0xF5F5F7), popupRowHover: Color(hex: 0xE8E8ED),
            popupItemTicked: Color(hex: 0x1D1D1F), checkboxTick: Color(hex: 0xFFFFFF), popupShadow: Color.black.opacity(0.18),
            progressTrack: Color(hex: 0xE5E5EA), zoomTrack: Color(hex: 0xD1D1D6), zoomFill: Color(hex: 0x8E8E93),
            zoomThumb: Color(hex: 0x3A3A3C))
    }

    /// The colours Increase Contrast changes (a11y design §2): every divider and border, and every
    /// text and icon colour softer than the primary. Four of them: standard and high contrast, on
    /// each side.
    struct ContrastPalette {
        let divStrong, divSoft, divRow, divTick, divOctave: Color
        let textButton, textIcon, textIconSoft, textLabel, textMuted, textDim: Color
        let textFaint, textFainter, textFaintest, textScale, textSeparator: Color
        let keyLabel, popupBorder, popupTitle, popupItem, checkboxBorder, dropZoneBorder, zoomIcon: Color

        /// The authored values, as `NnLook.h` wrote them.
        static let darkStandard = ContrastPalette(
            divStrong: Color(hex: 0x24262C), divSoft: Color(hex: 0x202227), divRow: Color(hex: 0x1E2024),
            divTick: Color(hex: 0x22242A), divOctave: Color(hex: 0x232529),
            textButton: Color(hex: 0xC2C6CC), textIcon: Color(hex: 0x9BA1AB), textIconSoft: Color(hex: 0x8E939C),
            textLabel: Color(hex: 0x7A808A), textMuted: Color(hex: 0x797F88), textDim: Color(hex: 0x6B7078),
            textFaint: Color(hex: 0x5D626B), textFainter: Color(hex: 0x585D65), textFaintest: Color(hex: 0x565B63),
            textScale: Color(hex: 0x4E535B), textSeparator: Color(hex: 0x33363C),
            keyLabel: Color(hex: 0x7C818A), popupBorder: Color(hex: 0x2E3138), popupTitle: Color(hex: 0x6B7078),
            popupItem: Color(hex: 0xA8ADB5), checkboxBorder: Color(hex: 0x3A3D44), dropZoneBorder: Color(hex: 0x2B2E35),
            zoomIcon: Color(hex: 0x585D65))

        /// Increase Contrast's values: the same roles, lifted toward the primary text.
        static let darkHigh = ContrastPalette(
            divStrong: Color(hex: 0x60656F), divSoft: Color(hex: 0x555A63), divRow: Color(hex: 0x4A4E57),
            divTick: Color(hex: 0x50545D), divOctave: Color(hex: 0x3E424A),
            textButton: Color(hex: 0xF2F4F7), textIcon: Color(hex: 0xE7E9EC), textIconSoft: Color(hex: 0xE7E9EC),
            textLabel: Color(hex: 0xC9CDD4), textMuted: Color(hex: 0xC9CDD4), textDim: Color(hex: 0xC2C6CC),
            textFaint: Color(hex: 0xB8BDC6), textFainter: Color(hex: 0xB8BDC6), textFaintest: Color(hex: 0xB8BDC6),
            textScale: Color(hex: 0xA8ADB5), textSeparator: Color(hex: 0x8E939C),
            // Dark on the white keys, where the authored grey is faint.
            keyLabel: Color(hex: 0x2A2D33), popupBorder: Color(hex: 0x8E939C), popupTitle: Color(hex: 0xC2C6CC),
            popupItem: Color(hex: 0xF2F4F7), checkboxBorder: Color(hex: 0xA8ADB5), dropZoneBorder: Color(hex: 0x8E939C),
            zoomIcon: Color(hex: 0xC2C6CC))

        /// The light side: dividers at the separator's strength, label and secondary text that
        /// pass 4.5:1 on the light panels, the faint roles no lighter than 3:1.
        static let lightStandard = ContrastPalette(
            divStrong: Color(hex: 0xD1D1D6), divSoft: Color(hex: 0xDEDEE3), divRow: Color(hex: 0xE5E5EA),
            divTick: Color(hex: 0xE5E5EA), divOctave: Color(hex: 0xD8D8DD),
            textButton: Color(hex: 0x3A3A3C), textIcon: Color(hex: 0x545458), textIconSoft: Color(hex: 0x636366),
            textLabel: Color(hex: 0x6C6C70), textMuted: Color(hex: 0x6C6C70), textDim: Color(hex: 0x6E6E73),
            textFaint: Color(hex: 0x86868B), textFainter: Color(hex: 0x86868B), textFaintest: Color(hex: 0x86868B),
            textScale: Color(hex: 0x98989D), textSeparator: Color(hex: 0xC7C7CC),
            keyLabel: Color(hex: 0x8E8E93), popupBorder: Color(hex: 0xD1D1D6), popupTitle: Color(hex: 0x6C6C70),
            popupItem: Color(hex: 0x2C2C2E), checkboxBorder: Color(hex: 0xAEAEB2), dropZoneBorder: Color(hex: 0xC7C7CC),
            zoomIcon: Color(hex: 0x8E8E93))

        /// Increase Contrast on the light side: dividers a mid grey, every text role at 7:1 or more.
        static let lightHigh = ContrastPalette(
            divStrong: Color(hex: 0x6E6E73), divSoft: Color(hex: 0x86868B), divRow: Color(hex: 0x98989D),
            divTick: Color(hex: 0x8E8E93), divOctave: Color(hex: 0xAEAEB2),
            textButton: Color(hex: 0x000000), textIcon: Color(hex: 0x1D1D1F), textIconSoft: Color(hex: 0x1D1D1F),
            textLabel: Color(hex: 0x2C2C2E), textMuted: Color(hex: 0x2C2C2E), textDim: Color(hex: 0x2C2C2E),
            textFaint: Color(hex: 0x3A3A3C), textFainter: Color(hex: 0x3A3A3C), textFaintest: Color(hex: 0x3A3A3C),
            textScale: Color(hex: 0x48484A), textSeparator: Color(hex: 0x6E6E73),
            keyLabel: Color(hex: 0x1D1D1F), popupBorder: Color(hex: 0x6E6E73), popupTitle: Color(hex: 0x2C2C2E),
            popupItem: Color(hex: 0x000000), checkboxBorder: Color(hex: 0x48484A), dropZoneBorder: Color(hex: 0x6E6E73),
            zoomIcon: Color(hex: 0x3A3A3C))

        static func pick(dark: Bool, highContrast: Bool) -> ContrastPalette {
            switch (dark, highContrast) {
            case (true, false): darkStandard
            case (true, true): darkHigh
            case (false, false): lightStandard
            case (false, true): lightHigh
            }
        }
    }

    /// The palette of the appearance the app is drawn in.
    static var palette: Palette {
        ThemeAppearance.shared.isDark ? .dark : .light
    }
}
