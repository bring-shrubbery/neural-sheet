import AppKit
import NeuralSheetCore
import SwiftUI

/// The sidebar's extents (native chrome design §4), shared with the strips.
nonisolated enum SidebarMetrics {
    /// The sidebar column's width.
    static let width: CGFloat = 268
    /// The side margin the strips and the mix keep inside the column.
    static let margin: CGFloat = 10
    /// A strip's width: the column less its margins.
    static let stripWidth: CGFloat = width - 2 * margin
}

/// The sidebar of the window's split view (native chrome design §4): the instruments the
/// transcription contains, each a strip, under an "Instruments" header with the picker's "+",
/// and the mix pinned to the bottom. The split view draws it as the system's floating glass
/// sidebar; nothing here paints a background.
///
/// The meters are the only thing here that moves per frame. Each strip is handed its own level
/// and compared before it is re-laid out, so a frame in which one meter moves redraws one meter.
struct MixerSidebar: View {
    let model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            header

            ScrollView(.vertical) {
                StripList(model: model)
                    .padding(.horizontal, SidebarMetrics.margin)
                    .padding(.bottom, 8)
            }
            .scrollBounceBehavior(.basedOnSize)
            .frame(maxHeight: .infinity)

            Divider()
                .padding(.horizontal, SidebarMetrics.margin + 6)

            MixSection(model: model)
                .padding(.horizontal, SidebarMetrics.margin + 6)
                .padding(.vertical, 12)
        }
        .frame(width: SidebarMetrics.width)
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 6) {
            Text("Instruments")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(Theme.textLabel)
                .accessibilityAddTraits(.isHeader)

            Spacer(minLength: 0)

            Text(model.mixer.entries.count, format: .number)
                .font(.system(size: 11).monospacedDigit())
                .foregroundStyle(Theme.textMuted)
                .accessibilityLabel(Text(AccessibilityText.instrumentCount(model.mixer.entries.count)))

            // The picker restricts the next run; once there is a transcription the strips are
            // what there is.
            if !model.state.hasTranscription {
                Button { model.isInstrumentMenuOpen = true } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 12, weight: .semibold))
                        .frame(width: 22, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .tooltip("Restrict the transcription to chosen instruments")
                .accessibilityLabel(Text(AccessibilityText.addInstrument))
                .popover(isPresented: Binding(get: { model.isInstrumentMenuOpen },
                                              set: { model.isInstrumentMenuOpen = $0 }),
                         arrowEdge: .trailing) {
                    InstrumentMenu(model: model)
                }
            }
        }
        .padding(.horizontal, SidebarMetrics.margin + 6)
        .frame(height: 30)
    }

    /// The strips, one per instrument in the mix.
    private struct StripList: View {
        let model: AppModel

        /// The strip card's panel, and whose strip it is up for.
        @State private var card = PopupMenuPresenter()
        @State private var cardProgram: Int?

        var body: some View {
            let editing = model.workspace == .edit

            VStack(spacing: 2) {
                ForEach(model.mixer.entries, id: \.program) { entry in
                    InstrumentStrip(model: model,
                                    entry: entry,
                                    settings: model.mixer.settings[entry.program] ?? InstrumentChannelSettings(),
                                    level: model.instrumentLevelDb(program: entry.program),
                                    width: SidebarMetrics.stripWidth,
                                    isTarget: editing && model.editor.targetProgram == entry.program,
                                    isHighlighted: model.highlightedProgram == entry.program,
                                    onSelect: { model.toggleHighlight(program: entry.program) },
                                    onSecondaryClick: editing ? { window, point in showCard(for: entry, in: window, at: point) } : nil)
                        .equatable()
                }
            }
            // The card is for a strip that is there and a tab that edits: gone with either.
            .onChange(of: model.mixer.entries.map(\.program)) { _, programs in
                if let cardProgram, !programs.contains(cardProgram) { card.dismiss() }
            }
            .onChange(of: model.canEdit) { _, canEdit in
                if !canEdit { card.dismiss() }
            }
            .onChange(of: model.workspace) { _, _ in
                card.dismiss()
            }
        }

        private func showCard(for entry: InstrumentEntry, in window: NSWindow, at windowPoint: CGPoint) {
            guard model.canEdit else { return }

            let card = card
            let model = model

            cardProgram = entry.program
            card.onDismiss = { cardProgram = nil }
            card.showPanel(at: window.convertPoint(toScreen: windowPoint), in: window, scale: 1) {
                InstrumentCard(model: model, entry: entry, host: card)
            }
        }
    }
}
