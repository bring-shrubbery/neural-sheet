import SwiftUI

/// The colours Increase Contrast changes (a11y design §2): every divider and border, and every
/// text and icon colour softer than the primary. Each token is the standard value of the
/// appearance the app is drawn in unless the accommodation is on, when it is its high-contrast
/// twin: borders strong enough to see and text that passes 7:1 (the four tables are
/// ``Theme/ContrastPalette``). Read through ``Accommodations`` and ``ThemeAppearance``, so a
/// SwiftUI body using one is drawn again when either flips.
extension Theme {
    /// The table in force: the appearance's, standard or high contrast.
    static var contrasted: ContrastPalette {
        ContrastPalette.pick(dark: ThemeAppearance.shared.isDark,
                             highContrast: Accommodations.shared.increaseContrast)
    }

    // MARK: - Dividers

    static var divStrong: Color { contrasted.divStrong }
    static var divSoft: Color { contrasted.divSoft }
    static var divRow: Color { contrasted.divRow }
    static var divTick: Color { contrasted.divTick }
    static var divOctave: Color { contrasted.divOctave }

    // MARK: - Text

    static var textButton: Color { contrasted.textButton }
    static var textIcon: Color { contrasted.textIcon }
    static var textIconSoft: Color { contrasted.textIconSoft }
    static var textLabel: Color { contrasted.textLabel }
    static var textMuted: Color { contrasted.textMuted }
    static var textDim: Color { contrasted.textDim }
    static var textFaint: Color { contrasted.textFaint }
    static var textFainter: Color { contrasted.textFainter }
    static var textFaintest: Color { contrasted.textFaintest }
    static var textScale: Color { contrasted.textScale }
    static var textSeparator: Color { contrasted.textSeparator }

    // MARK: - Keys, popups, empty states

    static var keyLabel: Color { contrasted.keyLabel }
    static var popupBorder: Color { contrasted.popupBorder }
    static var popupTitle: Color { contrasted.popupTitle }
    static var popupItem: Color { contrasted.popupItem }
    static var checkboxBorder: Color { contrasted.checkboxBorder }
    static var dropZoneBorder: Color { contrasted.dropZoneBorder }
    static var zoomIcon: Color { contrasted.zoomIcon }
}
