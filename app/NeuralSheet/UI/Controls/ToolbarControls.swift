import CoreText
import NeuralSheetCore
import SwiftUI

/// The toolbar rows' authored extents (`NnToolbar.cpp`, `nn::metrics`), which the cards' buttons
/// and fields still use now the rows are the window's toolbar (native chrome design §4).
enum ToolbarMetrics {
    static let height: CGFloat = 44
    static let paddingSide: CGFloat = 14
    static let groupGap: CGFloat = 12
    static let buttonHeight: CGFloat = 28
    static let corner: CGFloat = 6
    static let iconSize: CGFloat = 13
    static let buttonPadX: CGFloat = 12
    static let iconLabelGap: CGFloat = 7
}

// MARK: - Controls

/// The toolbar rows' controls, at the scale the caller reads from the environment: an icon
/// button, a label button and the caps pill label in front of a field. One definition, so the
/// cards that still use them look alike.
enum ToolbarControls {
    private typealias Metrics = ToolbarMetrics

    /// A square icon button, 4 short of the row's button height so three of them fit inside the
    /// tool tray's padding at the same height as the label buttons beside it.
    /// `label` names it for VoiceOver: the icon says nothing to it (a11y design §2).
    static func iconButton<Icon: Shape>(k: CGFloat, isOn: Bool, isEnabled: Bool = true, tooltip: String, label: Text,
                                        action: @escaping () -> Void, icon: () -> Icon) -> some View {
        let s = Scaled(k: k)
        let icon = icon()

        return FlatButton(isOn: isOn,
                          isEnabled: isEnabled,
                          idle: Theme.bgControlAlt,
                          on: Theme.accentFillActive,
                          foregroundIdle: Theme.textIconSoft,
                          foregroundOn: Theme.accentText,
                          corner: s(Metrics.corner),
                          action: action) { _ in
            icon.stroke(style: Icons.strokeStyle(scale: k))
                .frame(width: s(Metrics.iconSize), height: s(Metrics.iconSize))
                .frame(width: s(Metrics.buttonHeight - 4), height: s(Metrics.buttonHeight - 4))
        }
        .tooltip(tooltip)
        .accessibilityLabel(label)
    }

    /// A button showing its value -- a division, a key, a numerator -- takes a `label` saying what
    /// the value is of, and VoiceOver reads the title as its value; a button whose title is an
    /// action is named by the title (a11y design §2).
    static func labelButton(k: CGFloat, _ title: LocalizedStringResource, tooltip: LocalizedStringResource, label: Text? = nil,
                            isEnabled: Bool = true, action: @escaping () -> Void) -> some View {
        labelButton(k: k, String(localized: title), tooltip: tooltip, label: label, isEnabled: isEnabled, action: action)
    }

    /// The same button showing data -- a division, a tonic, a numerator -- or a title already
    /// localized. Disfavoured, so a literal takes the localized overload.
    @_disfavoredOverload
    static func labelButton<S: StringProtocol>(k: CGFloat, _ title: S, tooltip: LocalizedStringResource, label: Text? = nil,
                                               isEnabled: Bool = true, action: @escaping () -> Void) -> some View {
        let s = Scaled(k: k)
        let title = String(title)

        return FlatButton(isEnabled: isEnabled,
                          idle: Theme.bgControlAlt,
                          on: Theme.bgControlActive,
                          foregroundIdle: Theme.textButton,
                          foregroundOn: Theme.textBright,
                          corner: s(Metrics.corner),
                          action: action) { _ in
            Text(title)
                .font(Fonts.buttonLabel(k))
                .fixedSize()
                .padding(.horizontal, s(Metrics.buttonPadX))
                .frame(height: s(Metrics.buttonHeight))
        }
        .tooltip(tooltip)
        .accessibilityLabel(label ?? Text(verbatim: title))
        .accessibilityValue(label == nil ? Text(verbatim: "") : Text(verbatim: title))
    }

    /// The tracked caps label the sidebar's pills use, in front of each field.
    static func pillLabel(k: CGFloat, _ text: LocalizedStringResource) -> some View {
        pillLabel(k: k, String(localized: text))
    }

    /// The same label for a sign or text already localized.
    @_disfavoredOverload
    static func pillLabel<S: StringProtocol>(k: CGFloat, _ text: S) -> some View {
        TrackedLabel(string: String(text), em: Fonts.Tracking.pillLabel, pointSize: Fonts.Size.pillLabel,
                     font: Fonts.pillLabel(k), scale: k)
            .foregroundStyle(Theme.textLabel)
    }
}

// MARK: - Tracked text

/// Letter-spaced text the way `nn::drawTrackedText` lays it out: glyph *i* shifted by
/// `i * em * pointSize`, which puts a gap after every glyph but the last. `kerning` on its own adds
/// one after the last glyph too, and that trailing gap is what would make a measured or
/// right-aligned label a fraction wide.
struct TrackedLabel: View {
    let string: String
    let em: Double
    let pointSize: CGFloat
    let font: Font
    let scale: CGFloat

    var body: some View {
        let spacing = Fonts.tracking(em, pointSize: pointSize, scale: scale)

        if string.count > 1 {
            let head = Text(String(string.dropLast())).kerning(spacing)
            let tail = Text(String(string.suffix(1)))

            Text("\(head)\(tail)")
                .font(font)
        } else {
            Text(string).font(font)
        }
    }
}


/// The width `nn::trackedTextWidth` gave a label: the natural advance plus one tracking step per
/// gap between glyphs, measured at the authored size. The caller scales the result.
enum TrackedText {
    static func width(_ text: String, fontName: String, pointSize: CGFloat, trackingEm: Double) -> CGFloat {
        let font = CTFontCreateWithName(fontName as CFString, pointSize, nil)
        let attributed = NSAttributedString(string: text, attributes: [.font: font])
        let line = CTLineCreateWithAttributedString(attributed)
        let natural = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
        let gaps = CGFloat(max(0, text.count - 1))

        return natural + gaps * CGFloat(trackingEm) * pointSize
    }
}
