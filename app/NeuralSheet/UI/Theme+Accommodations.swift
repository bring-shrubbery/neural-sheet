import SwiftUI

/// The colours Increase Contrast changes (a11y design §2): every divider and border, and every
/// text and icon colour softer than the primary. Each token is the authored value from
/// `nn::colours` (``Standard``) unless the accommodation is on, when it is its high-contrast
/// twin (``HighContrast``): borders strong enough to see against the dark surfaces and text
/// that passes 7:1 on them. Read through ``Accommodations``, so a SwiftUI body using one is drawn
/// again when the setting flips.
extension Theme {
    /// The authored values, as `NnLook.h` wrote them.
    enum Standard {
        static let divStrong = Color(hex: 0x24262C)
        static let divSoft = Color(hex: 0x202227)
        static let divRow = Color(hex: 0x1E2024)
        static let divTick = Color(hex: 0x22242A)
        static let divOctave = Color(hex: 0x232529)

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

        static let keyLabel = Color(hex: 0x7C818A)
        static let popupBorder = Color(hex: 0x2E3138)
        static let popupTitle = Color(hex: 0x6B7078)
        static let popupItem = Color(hex: 0xA8ADB5)
        static let checkboxBorder = Color(hex: 0x3A3D44)
        static let dropZoneBorder = Color(hex: 0x2B2E35)
        static let zoomIcon = Color(hex: 0x585D65)
    }

    /// Increase Contrast's values: the same roles, lifted toward the primary text.
    enum HighContrast {
        static let divStrong = Color(hex: 0x60656F)
        static let divSoft = Color(hex: 0x555A63)
        static let divRow = Color(hex: 0x4A4E57)
        static let divTick = Color(hex: 0x50545D)
        static let divOctave = Color(hex: 0x3E424A)

        static let textButton = Color(hex: 0xF2F4F7)
        static let textIcon = Color(hex: 0xE7E9EC)
        static let textIconSoft = Color(hex: 0xE7E9EC)
        static let textLabel = Color(hex: 0xC9CDD4)
        static let textMuted = Color(hex: 0xC9CDD4)
        static let textDim = Color(hex: 0xC2C6CC)
        static let textFaint = Color(hex: 0xB8BDC6)
        static let textFainter = Color(hex: 0xB8BDC6)
        static let textFaintest = Color(hex: 0xB8BDC6)
        static let textScale = Color(hex: 0xA8ADB5)
        static let textSeparator = Color(hex: 0x8E939C)

        /// Dark on the white keys, where the authored grey is faint.
        static let keyLabel = Color(hex: 0x2A2D33)
        static let popupBorder = Color(hex: 0x8E939C)
        static let popupTitle = Color(hex: 0xC2C6CC)
        static let popupItem = Color(hex: 0xF2F4F7)
        static let checkboxBorder = Color(hex: 0xA8ADB5)
        static let dropZoneBorder = Color(hex: 0x8E939C)
        static let zoomIcon = Color(hex: 0xC2C6CC)
    }

    private static var contrast: Bool { Accommodations.shared.increaseContrast }

    // MARK: - Dividers

    static var divStrong: Color { contrast ? HighContrast.divStrong : Standard.divStrong }
    static var divSoft: Color { contrast ? HighContrast.divSoft : Standard.divSoft }
    static var divRow: Color { contrast ? HighContrast.divRow : Standard.divRow }
    static var divTick: Color { contrast ? HighContrast.divTick : Standard.divTick }
    static var divOctave: Color { contrast ? HighContrast.divOctave : Standard.divOctave }

    // MARK: - Text

    static var textButton: Color { contrast ? HighContrast.textButton : Standard.textButton }
    static var textIcon: Color { contrast ? HighContrast.textIcon : Standard.textIcon }
    static var textIconSoft: Color { contrast ? HighContrast.textIconSoft : Standard.textIconSoft }
    static var textLabel: Color { contrast ? HighContrast.textLabel : Standard.textLabel }
    static var textMuted: Color { contrast ? HighContrast.textMuted : Standard.textMuted }
    static var textDim: Color { contrast ? HighContrast.textDim : Standard.textDim }
    static var textFaint: Color { contrast ? HighContrast.textFaint : Standard.textFaint }
    static var textFainter: Color { contrast ? HighContrast.textFainter : Standard.textFainter }
    static var textFaintest: Color { contrast ? HighContrast.textFaintest : Standard.textFaintest }
    static var textScale: Color { contrast ? HighContrast.textScale : Standard.textScale }
    static var textSeparator: Color { contrast ? HighContrast.textSeparator : Standard.textSeparator }

    // MARK: - Keys, popups, empty states

    static var keyLabel: Color { contrast ? HighContrast.keyLabel : Standard.keyLabel }
    static var popupBorder: Color { contrast ? HighContrast.popupBorder : Standard.popupBorder }
    static var popupTitle: Color { contrast ? HighContrast.popupTitle : Standard.popupTitle }
    static var popupItem: Color { contrast ? HighContrast.popupItem : Standard.popupItem }
    static var checkboxBorder: Color { contrast ? HighContrast.checkboxBorder : Standard.checkboxBorder }
    static var dropZoneBorder: Color { contrast ? HighContrast.dropZoneBorder : Standard.dropZoneBorder }
    static var zoomIcon: Color { contrast ? HighContrast.zoomIcon : Standard.zoomIcon }
}
