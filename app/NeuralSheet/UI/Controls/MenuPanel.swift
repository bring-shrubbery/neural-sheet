import SwiftUI

/// The fixed extents every menu and popup panel is laid out against (`nn::metrics`, §1.12).
/// Authored numbers: multiply by the UI scale at the point of use.
nonisolated enum MenuMetrics {
    static let width: CGFloat = 244
    static let corner: CGFloat = 8
    static let headerHeight: CGFloat = 28
    static let footerHeight: CGFloat = 29
    static let rowHeight: CGFloat = 30
    /// The list scrolls beyond this.
    static let listMaxHeight: CGFloat = 274
    static let padX: CGFloat = 11
    static let listPadY: CGFloat = 4
    static let checkboxSize: CGFloat = 14
    static let checkboxCorner: CGFloat = 3
    /// The tick is stroked heavier than the icon set, so it reads inside a 14 px box.
    static let checkboxTickStroke: CGFloat = 2
    /// A separator is a 1 px line in a row of this height.
    static let separatorHeight: CGFloat = 9
    static let minWidth: CGFloat = 180
}

/// The panel the instrument dropdown and every popup menu share: a popup surface, an optional
/// header, a scrolling list of rows and an optional footer.
struct MenuPanel<Content: View>: View {
    var title: String?
    var footer: String?
    /// Already scaled by the caller; defaults to the authored 244 at 1x.
    var width: CGFloat?
    @ViewBuilder var content: () -> Content

    @Environment(\.uiScale) private var k

    init(title: String? = nil,
         footer: String? = nil,
         width: CGFloat? = nil,
         @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.footer = footer
        self.width = width
        self.content = content
    }

    var body: some View {
        let s = Scaled(k: k)

        VStack(spacing: 0) {
            if let title {
                Text(title)
                    .font(Fonts.sectionHeader(k))
                    .kerning(Fonts.tracking(Fonts.Tracking.sectionHeader,
                                            pointSize: Fonts.Size.sectionHeader,
                                            scale: k))
                    .foregroundStyle(Theme.popupTitle)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, s(MenuMetrics.padX))
                    .frame(height: s(MenuMetrics.headerHeight))
            }

            ScrollView(.vertical) {
                VStack(spacing: 0) {
                    content()
                }
                .padding(.vertical, s(MenuMetrics.listPadY))
            }
            .scrollBounceBehavior(.basedOnSize)
            .frame(maxHeight: s(MenuMetrics.listMaxHeight))

            if let footer {
                Text(footer)
                    .font(Fonts.menuItem(k))
                    .foregroundStyle(Theme.popupTitle)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, s(MenuMetrics.padX))
                    .frame(height: s(MenuMetrics.footerHeight))
                    .background(Theme.popupFooterBg)
            }
        }
        .frame(width: width ?? s(MenuMetrics.width))
        .fixedSize(horizontal: false, vertical: true)
        .popupSurface(corner: s(MenuMetrics.corner))
    }
}

/// One row of a `MenuPanel`.
///
/// Nothing is drawn for an unticked row, and the tick sits at the right-hand end: a menu item here
/// is as often an action as a toggle, and an empty box beside "Check for updates" would promise a
/// state it does not have.
struct MenuRow: View {
    let title: String
    var isTicked: Bool = false
    var isEnabled: Bool = true
    /// An instrument's colour, shown as a small swatch before the title; nil draws none.
    var chip: Color? = nil
    let action: () -> Void

    @Environment(\.uiScale) private var k
    @State private var isHovered = false

    private static let chipSize: CGFloat = 10
    private static let chipCorner: CGFloat = 2.5
    private static let chipGap: CGFloat = 8

    var body: some View {
        let s = Scaled(k: k)

        HStack(spacing: 0) {
            if let chip {
                let shape = RoundedRectangle(cornerRadius: s(Self.chipCorner), style: .circular)

                ZStack {
                    shape.fill(Theme.chipFill(chip))
                    shape.strokeBorder(Theme.chipBorder(chip), lineWidth: k)
                }
                .frame(width: s(Self.chipSize), height: s(Self.chipSize))
                .padding(.trailing, s(Self.chipGap))
            }

            Text(title)
                .font(isTicked ? Fonts.menuItemTicked(k) : Fonts.menuItem(k))
                .foregroundStyle(isTicked ? Theme.popupItemTicked : Theme.popupItem)
                .lineLimit(1)
                .truncationMode(.tail)

            Spacer(minLength: s(MenuMetrics.padX))

            MenuCheckbox(isTicked: true)
                .opacity(isTicked ? 1 : 0)
        }
        .padding(.horizontal, s(MenuMetrics.padX))
        .frame(height: s(MenuMetrics.rowHeight))
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(isHovered && isEnabled ? Theme.popupRowHover : .clear)
        .opacity(isEnabled ? 1 : Theme.disabledAlpha)
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        .onTapGesture { if isEnabled { action() } }
        .pointerStyle(isEnabled ? .link : nil)
        .accessibilityAddTraits(.isButton)
    }
}

/// A section's label inside a menu: the header typography at a row's inset, for a list that
/// falls into groups.
struct MenuSectionLabel: View {
    let title: String

    @Environment(\.uiScale) private var k

    private static let height: CGFloat = 22

    var body: some View {
        let s = Scaled(k: k)

        Text(title)
            .font(Fonts.sectionHeader(k))
            .kerning(Fonts.tracking(Fonts.Tracking.sectionHeader, pointSize: Fonts.Size.sectionHeader, scale: k))
            .foregroundStyle(Theme.popupTitle)
            .lineLimit(1)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, s(MenuMetrics.padX))
            .frame(height: s(Self.height))
    }
}

/// A 1 px `divStrong` line in a 9 px row, as the menus draw their separators.
struct MenuSeparator: View {
    @Environment(\.uiScale) private var k

    var body: some View {
        let s = Scaled(k: k)

        Rectangle()
            .fill(Theme.divStrong)
            .frame(height: k)
            .frame(maxWidth: .infinity)
            .frame(height: s(MenuMetrics.separatorHeight))
    }
}

/// The tick box the instrument dropdown and the popup menus share (`nn::drawCheckbox`).
struct MenuCheckbox: View {
    let isTicked: Bool

    @Environment(\.uiScale) private var k

    var body: some View {
        let s = Scaled(k: k)
        let side = s(MenuMetrics.checkboxSize)
        let shape = RoundedRectangle(cornerRadius: s(MenuMetrics.checkboxCorner), style: .circular)

        ZStack {
            if isTicked {
                shape.fill(Theme.accent)
                Icons.CheckStroked()
                    .stroke(Theme.checkboxTick,
                            style: StrokeStyle(lineWidth: s(MenuMetrics.checkboxTickStroke),
                                               lineCap: .round,
                                               lineJoin: .round))
            } else {
                shape.strokeBorder(Theme.checkboxBorder, lineWidth: k)
            }
        }
        .frame(width: side, height: side)
    }
}
