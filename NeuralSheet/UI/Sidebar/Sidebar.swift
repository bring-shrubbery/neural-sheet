import NeuralSheetCore
import SwiftUI

/// The sidebar's authored extents (`nn::metrics`, `Sidebar.cpp`), shared with the strips, the
/// master panel and the instrument picker's anchor.
nonisolated enum SidebarMetrics {
    static let width: CGFloat = 262
    /// The column the header, the strips and the master panel are laid out in: the sidebar less
    /// its 1 px right border.
    static let stripWidth: CGFloat = width - 1
    static let headerHeight: CGFloat = 38
    static let stripHeight: CGFloat = 76
    /// Where the instrument picker's top-right corner goes, from the sidebar's own origin.
    static let menuAnchorRight: CGFloat = 10
    static let menuAnchorTop: CGFloat = 33
}

/// The instrument mixer down the left of the window (§1.4): a header, one strip per instrument
/// the transcription contains, and the master panel pinned to the bottom.
///
/// The meters are the only thing here that moves per frame. Each strip is handed its own level
/// and compared before it is re-laid out, so a frame in which one meter moves redraws one meter.
struct Sidebar: View {
    let model: AppModel

    @Environment(\.uiScale) private var k

    // MARK: - Authored extents (`Sidebar.cpp`)

    private static let paddingSide: CGFloat = 14
    private static let headerGap: CGFloat = 8
    private static let addButtonSize: CGFloat = 18
    private static let addButtonCorner: CGFloat = 4
    private static let addIconSize: CGFloat = 13

    var body: some View {
        let s = Scaled(k: k)

        VStack(spacing: 0) {
            header

            ScrollView(.vertical) {
                VStack(spacing: 0) {
                    ForEach(model.mixer.entries, id: \.program) { entry in
                        InstrumentStrip(model: model,
                                        entry: entry,
                                        settings: model.mixer.settings[entry.program] ?? InstrumentChannelSettings(),
                                        level: model.instrumentLevelDb(program: entry.program))
                            .equatable()
                    }
                }
            }
            .scrollBounceBehavior(.basedOnSize)
            .frame(maxHeight: .infinity)

            MasterPanel(level: model.masterLevelDb)
        }
        .frame(width: s(SidebarMetrics.stripWidth))
        .frame(width: s(SidebarMetrics.width), alignment: .leading)
        .frame(maxHeight: .infinity)
        .background(Theme.bgSidebar)
        .overlay(alignment: .trailing) {
            Rectangle()
                .fill(Theme.divStrong)
                .frame(width: k)
        }
        .clipped()
    }

    // MARK: - Header

    private var header: some View {
        let s = Scaled(k: k)
        let showsAdd = !model.state.hasTranscription
        // The count keeps clear of the "+" while there is one, and takes its room once it has gone.
        let countTrailing = showsAdd ? Self.addButtonSize + Self.headerGap : 0

        return ZStack(alignment: .leading) {
            Text("INSTRUMENTS")
                .font(Fonts.sectionHeader(k))
                .kerning(Fonts.tracking(Fonts.Tracking.sectionHeader,
                                        pointSize: Fonts.Size.sectionHeader,
                                        scale: k))
                .foregroundStyle(Theme.textLabel)
                .lineLimit(1)

            Text("\(model.mixer.entries.count)")
                .font(Fonts.mono(10, weight: 400, scale: k))
                .foregroundStyle(Theme.textFaintest)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .trailing)
                .padding(.trailing, s(countTrailing))

            if showsAdd {
                addButton
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
        .padding(.horizontal, s(Self.paddingSide))
        .frame(height: s(SidebarMetrics.headerHeight))
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Theme.divSoft)
                .frame(height: k)
        }
    }

    /// Only ever opens the picker: while the menu is up its scrim covers the "+" as well, so a
    /// second click there is the click that closes it. Lit while the menu is on screen.
    private var addButton: some View {
        let s = Scaled(k: k)

        return FlatButton(isOn: model.isInstrumentMenuOpen,
                          idle: Theme.bgControlSubtle,
                          on: Theme.accent.opacity(0.18),
                          foregroundIdle: Theme.textIconSoft,
                          foregroundOn: Theme.accentText,
                          corner: s(Self.addButtonCorner),
                          action: { model.isInstrumentMenuOpen = true }) { _ in
            Icons.PlusStroked()
                .stroke(style: Icons.strokeStyle(scale: k))
                .frame(width: s(Self.addIconSize), height: s(Self.addIconSize))
                .frame(width: s(Self.addButtonSize), height: s(Self.addButtonSize))
        }
        .tooltip("Restrict the transcription to chosen instruments")
        .accessibilityLabel("Add instrument")
    }
}

#Preview("Sidebar") {
    let model = AppModel()

    return Sidebar(model: model)
        .frame(height: 746)
        .background(Theme.bgRoot)
        .onAppear {
            model.setSelected(.acousticPiano, true)
            model.setSelected(.electricBass, true)
            model.setSelected(.drums, true)
        }
}
