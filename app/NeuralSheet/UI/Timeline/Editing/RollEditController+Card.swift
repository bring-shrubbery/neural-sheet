import AppKit
import NeuralSheetCore
import SwiftUI

/// The note card: a right-click on a note opens the selection's five fields in a floating panel
/// at the pointer, so a note can be set without a trip to the sidebar. It follows the selection
/// while it is up and goes with the next click elsewhere, with Escape, or when nothing is
/// selected any more.
extension RollEditController {
    func showNoteCard(at windowPoint: CGPoint) {
        guard let window = roll.window else { return }

        let model = model
        let host = noteCard

        noteCard.showPanel(at: window.convertPoint(toScreen: windowPoint), in: window, scale: geometry.scale) {
            NoteCard(model: model, host: host)
        }
    }

    /// The container's sync: a card for no note is no card.
    func selectionDidChange(_ selection: Set<NoteID>) {
        if selection.isEmpty {
            noteCard.dismiss()
        }
    }
}

/// What the card shows: the count as its header, then ``SelectionFields`` on the popup surface.
struct NoteCard: View {
    let model: AppModel
    let host: PopupMenuPresenter

    @Environment(\.uiScale) private var k

    static let width: CGFloat = 236
    private static let padding: CGFloat = 12
    private static let labelHeight: CGFloat = 12

    var body: some View {
        let s = Scaled(k: k)

        VStack(alignment: .leading, spacing: 0) {
            Text(SelectionFields.countText(model.editor.selection.count).uppercased())
                .font(Fonts.sectionHeader(k))
                .kerning(Fonts.tracking(Fonts.Tracking.sectionHeader, pointSize: Fonts.Size.sectionHeader, scale: k))
                .foregroundStyle(Theme.popupTitle)
                .lineLimit(1)
                .frame(height: s(Self.labelHeight), alignment: .leading)

            SelectionFields(model: model, host: host)
                .padding(.top, s(8))
        }
        .padding(s(Self.padding))
        .frame(width: s(Self.width))
        .popupSurface(corner: s(MenuMetrics.corner), shadow: false)
    }
}
