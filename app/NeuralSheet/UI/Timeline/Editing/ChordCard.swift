import AppKit
import NeuralSheetCore
import SwiftUI

/// The chord card (chord symbols design §2): a click on a symbol in the chord lane opens its
/// root, quality and bass in a floating panel, the note card's style, with Delete. It reads the
/// list live, so a choice shows at once in the card, the lane and the score; the menus open as
/// the card's children (`host`), so choosing from one does not close the card.
struct ChordCard: View {
    let model: AppModel
    /// The event's index in the list when the card opened.
    let index: Int
    let host: PopupMenuPresenter

    @Environment(\.uiScale) private var k
    @State private var rootMenu = PopupMenuPresenter()
    @State private var rootAnchor: NSView?
    @State private var qualityMenu = PopupMenuPresenter()
    @State private var qualityAnchor: NSView?
    @State private var bassMenu = PopupMenuPresenter()
    @State private var bassAnchor: NSView?

    private static let padding: CGFloat = 12
    private static let labelHeight: CGFloat = 12

    var body: some View {
        let s = Scaled(k: k)
        let chords = model.chords

        VStack(alignment: .leading, spacing: 0) {
            if chords.indices.contains(index) {
                let event = chords[index]

                Text("Chord at \(model.editor.grid.barBeatLabel(at: event.seconds + 1e-6))".uppercased())
                    .font(Fonts.sectionHeader(k))
                    .kerning(Fonts.tracking(Fonts.Tracking.sectionHeader, pointSize: Fonts.Size.sectionHeader, scale: k))
                    .foregroundStyle(Theme.popupTitle)
                    .lineLimit(1)
                    .frame(height: s(Self.labelHeight), alignment: .leading)

                VStack(spacing: s(SelectionFields.rowGap)) {
                    row("Root") {
                        ToolbarControls.labelButton(k: k, event.chord.map { MusicalKey.tonicMenuName($0.root) } ?? ChordEvent.noChordText,
                                                    tooltip: "The chord's root, or no chord") { showRootMenu(event) }
                            .background(AnchorCatcher { rootAnchor = $0 })
                    }

                    row("Quality") {
                        ToolbarControls.labelButton(k: k, event.chord.map { Self.name(of: $0.quality) } ?? "—",
                                                    tooltip: "Major, minor, a seventh…", isEnabled: event.chord != nil) { showQualityMenu(event) }
                            .background(AnchorCatcher { qualityAnchor = $0 })
                    }

                    row("Bass") {
                        ToolbarControls.labelButton(k: k, event.chord?.slashBass.map(MusicalKey.tonicMenuName) ?? "None",
                                                    tooltip: "The note under the chord, written after a slash",
                                                    isEnabled: event.chord != nil) { showBassMenu(event) }
                            .background(AnchorCatcher { bassAnchor = $0 })
                    }
                }
                .padding(.top, s(8))

                FlatButton(idle: Theme.bgControlAlt, on: Theme.bgControlActive,
                           foregroundIdle: Theme.warn, foregroundOn: Theme.textBright,
                           corner: s(NumberField.corner), action: delete) { _ in
                    Text("Delete")
                        .font(Fonts.buttonLabel(k))
                        .fixedSize()
                        .padding(.horizontal, s(10))
                        .frame(height: s(NumberField.height))
                }
                .padding(.top, s(10))
            }
        }
        .padding(s(Self.padding))
        .frame(width: s(NoteCard.width))
        .popupSurface(corner: s(MenuMetrics.corner), shadow: false)
        // A menu left up would outlive the button it hangs from, with its monitors and observers.
        .onDisappear {
            rootMenu.dismiss()
            qualityMenu.dismiss()
            bassMenu.dismiss()
        }
    }

    /// The quality as the menu names it: the triads in words, the rest by their suffix.
    nonisolated static func name(of quality: ChordQuality) -> String {
        switch quality {
        case .major: "Major"
        case .minor: "Minor"
        case .diminished: "Diminished"
        case .augmented: "Augmented"
        case .sus2: "Sus2"
        case .sus4: "Sus4"
        default: quality.suffix
        }
    }

    private func delete() {
        host.dismiss()
        model.removeChord(at: index)
    }

    // MARK: - Menus

    private func showRootMenu(_ event: ChordEvent) {
        let titles = [ChordEvent.noChordText] + (0..<12).map(MusicalKey.tonicMenuName)

        show(rootMenu, from: rootAnchor, titles: titles) { menu in
            MenuRow(title: ChordEvent.noChordText, isTicked: event.chord == nil) {
                menu.dismiss()
                model.setChord(at: index, nil)
            }

            MenuSeparator()

            ForEach(0..<12, id: \.self) { root in
                MenuRow(title: MusicalKey.tonicMenuName(root), isTicked: event.chord?.root == root) {
                    menu.dismiss()
                    let quality = event.chord?.quality ?? .major
                    let bass = event.chord?.bass.flatMap { $0 == root ? nil : $0 }
                    model.setChord(at: index, ChordSymbol(root: root, quality: quality, bass: bass))
                }
            }
        }
    }

    private func showQualityMenu(_ event: ChordEvent) {
        guard let chord = event.chord else { return }

        show(qualityMenu, from: qualityAnchor, titles: ChordQuality.allCases.map(Self.name(of:))) { menu in
            ForEach(ChordQuality.allCases, id: \.self) { quality in
                MenuRow(title: Self.name(of: quality), isTicked: chord.quality == quality) {
                    menu.dismiss()
                    model.setChord(at: index, ChordSymbol(root: chord.root, quality: quality, bass: chord.bass))
                }
            }
        }
    }

    private func showBassMenu(_ event: ChordEvent) {
        guard let chord = event.chord else { return }

        show(bassMenu, from: bassAnchor, titles: ["None"] + (0..<12).map(MusicalKey.tonicMenuName)) { menu in
            MenuRow(title: "None", isTicked: chord.slashBass == nil) {
                menu.dismiss()
                model.setChord(at: index, ChordSymbol(root: chord.root, quality: chord.quality, bass: nil))
            }

            MenuSeparator()

            ForEach(0..<12, id: \.self) { bass in
                MenuRow(title: MusicalKey.tonicMenuName(bass), isTicked: chord.slashBass == bass, isEnabled: bass != chord.root) {
                    menu.dismiss()
                    model.setChord(at: index, ChordSymbol(root: chord.root, quality: chord.quality, bass: bass))
                }
            }
        }
    }

    /// Under its button, as a child of the card, which keeps the key.
    private func show<Rows: View>(_ menu: PopupMenuPresenter, from anchor: NSView?, titles: [String],
                                  @ViewBuilder rows: (PopupMenuPresenter) -> Rows) {
        guard let anchor, let window = anchor.window else { return }

        let target = window.convertToScreen(anchor.convert(anchor.bounds, to: nil))
        let width = PopupMenuPresenter.width(forTitles: titles, scale: k)

        host.child = menu
        menu.show(targetScreenRect: target, in: window, width: width, scale: k, placement: .alignedToTarget,
                  becomesKey: false) {
            rows(menu)
        }
    }

    private func row<Control: View>(_ label: String, @ViewBuilder control: () -> Control) -> some View {
        let s = Scaled(k: k)

        return HStack(spacing: 0) {
            Text(label)
                .font(Fonts.meta(k))
                .foregroundStyle(Theme.textMuted)

            Spacer(minLength: 0)

            control()
        }
        .frame(height: s(SelectionFields.rowHeight))
    }
}
