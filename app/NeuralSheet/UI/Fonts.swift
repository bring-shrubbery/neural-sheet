import CoreText
import Foundation
import SwiftUI

/// Registers the TTF files bundled with the app so SwiftUI can reference them by family name.
enum FontRegistry {
    static func registerBundledFonts() {
        guard let urls = Bundle.main.urls(forResourcesWithExtension: "ttf", subdirectory: nil) else { return }
        for url in urls {
            CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
        }
    }
}

/// The type ramp, ported from `nn::fonts`.
///
/// The rule the original states: anything read as *data* (times, dB, counts, tempo, key labels) is
/// JetBrains Mono NL; labels and names are Inter. Sizes are point heights, which is what
/// `Font.custom(_:fixedSize:)` takes and what the mockup's CSS pixels are.
///
/// Every accessor takes the UI scale, so a view writes `Fonts.buttonLabel(k)` and never multiplies
/// a size itself.
enum Fonts {
    /// PostScript names, read back from the bundled TTFs after registration
    /// (`CTFontManagerCreateFontDescriptorsFromURL` -> `kCTFontNameAttribute`).
    enum Name {
        static let interRegular = "Inter-Regular"
        static let interMedium = "Inter-Medium"
        static let interSemiBold = "Inter-SemiBold"
        static let interBold = "Inter-Bold"
        static let monoRegular = "JetBrainsMonoNL-Regular"
        static let monoMedium = "JetBrainsMonoNL-Medium"
        static let monoSemiBold = "JetBrainsMonoNL-SemiBold"
    }

    /// Authored point heights, for laying a row out around a label and for `tracking`.
    enum Size {
        static let transportTime: CGFloat = 15
        static let transportTotal: CGFloat = 11
        static let filename: CGFloat = 12.5
        static let instrumentName: CGFloat = 12
        static let buttonLabel: CGFloat = 11.5
        static let menuItem: CGFloat = 11.5
        static let menuItemTicked: CGFloat = 11.5
        static let sectionHeader: CGFloat = 10
        static let pillLabel: CGFloat = 9.5
        static let statusBar: CGFloat = 9.5
        static let meta: CGFloat = 9
        static let metaStrong: CGFloat = 9
        static let scaleLabel: CGFloat = 7.5
    }

    /// Letter-spacing as a fraction of the em, as in CSS. Pass one of these to `tracking`.
    enum Tracking {
        static let sectionHeader: Double = 0.13
        /// The top bar's pills run their section headers tighter.
        static let sectionHeaderPill: Double = 0.09
        static let pillLabel: Double = 0.08
        static let pillLabelWide: Double = 0.09
    }

    // MARK: - Families

    /// Inter at a point height, picking the face the weight maps onto.
    static func sans(_ pointSize: CGFloat, weight: Int, scale: CGFloat = 1) -> Font {
        Font.custom(sansName(weight), fixedSize: pointSize * scale)
    }

    /// JetBrains Mono NL at a point height, picking the face the weight maps onto.
    static func mono(_ pointSize: CGFloat, weight: Int, scale: CGFloat = 1) -> Font {
        Font.custom(monoName(weight), fixedSize: pointSize * scale)
    }

    static func sansName(_ weight: Int) -> String {
        if weight >= 700 { return Name.interBold }
        if weight >= 600 { return Name.interSemiBold }
        if weight >= 500 { return Name.interMedium }

        return Name.interRegular
    }

    static func monoName(_ weight: Int) -> String {
        if weight >= 600 { return Name.monoSemiBold }
        if weight >= 500 { return Name.monoMedium }

        return Name.monoRegular
    }

    // MARK: - The ramp

    static func transportTime(_ s: CGFloat) -> Font { mono(Size.transportTime, weight: 500, scale: s) }

    static func transportTotal(_ s: CGFloat) -> Font { mono(Size.transportTotal, weight: 400, scale: s) }

    static func filename(_ s: CGFloat) -> Font { sans(Size.filename, weight: 500, scale: s) }

    static func instrumentName(_ s: CGFloat) -> Font { sans(Size.instrumentName, weight: 500, scale: s) }

    static func buttonLabel(_ s: CGFloat) -> Font { sans(Size.buttonLabel, weight: 500, scale: s) }

    static func menuItem(_ s: CGFloat) -> Font { sans(Size.menuItem, weight: 400, scale: s) }

    /// A ticked row is the one thing in a menu the eye should land on, so it carries weight as well
    /// as the accent box.
    static func menuItemTicked(_ s: CGFloat) -> Font { sans(Size.menuItemTicked, weight: 500, scale: s) }

    static func sectionHeader(_ s: CGFloat) -> Font { sans(Size.sectionHeader, weight: 600, scale: s) }

    static func pillLabel(_ s: CGFloat) -> Font { sans(Size.pillLabel, weight: 500, scale: s) }

    static func statusBar(_ s: CGFloat) -> Font { mono(Size.statusBar, weight: 400, scale: s) }

    static func meta(_ s: CGFloat) -> Font { mono(Size.meta, weight: 400, scale: s) }

    static func metaStrong(_ s: CGFloat) -> Font { mono(Size.metaStrong, weight: 600, scale: s) }

    static func scaleLabel(_ s: CGFloat) -> Font { mono(Size.scaleLabel, weight: 400, scale: s) }

    // MARK: - Tracking

    /// Letter-spacing in points, for `Text.kerning`. The em is what CSS resolves an "em" against:
    /// the point height, not the line height.
    static func tracking(_ em: Double, pointSize: CGFloat, scale: CGFloat) -> CGFloat {
        CGFloat(em) * pointSize * scale
    }
}
