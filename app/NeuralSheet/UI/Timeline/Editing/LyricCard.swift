import AppKit
import NeuralSheetCore
import SwiftUI

/// The lyric card (markers and lyrics design §2; issue #18, requirement 9): a floating panel in
/// the note card's style, hanging under the note it is entering a syllable for. The field holds
/// the note's syllable as typed — the text, "-" when the word goes on, "_" when it is held —
/// and Return or Tab commits it and steps to the next note of the instrument, the panel following
/// it; Escape closes the card without committing the field. Each commit is one undoable edit.
struct LyricCard: View {
    let model: AppModel

    @Environment(\.uiScale) private var k
    @State private var draft = ""
    @FocusState private var isFocused: Bool

    private static let padding: CGFloat = 12
    private static let labelHeight: CGFloat = 12

    var body: some View {
        let s = Scaled(k: k)
        let note = model.editor.lyricNote.flatMap { model.document?.note($0)?.note }

        VStack(alignment: .leading, spacing: 0) {
            Text(header(note).uppercased())
                .font(Fonts.sectionHeader(k))
                .kerning(Fonts.tracking(Fonts.Tracking.sectionHeader, pointSize: Fonts.Size.sectionHeader, scale: k))
                .foregroundStyle(Theme.popupTitle)
                .lineLimit(1)
                .frame(height: s(Self.labelHeight), alignment: .leading)
                .accessibilityAddTraits(.isHeader)

            TextField("", text: $draft)
                .textFieldStyle(.plain)
                .font(Fonts.meta(k))
                .foregroundStyle(Theme.textStrong)
                .focused($isFocused)
                .padding(.horizontal, s(6))
                .frame(height: s(NumberField.height))
                .background(RoundedRectangle(cornerRadius: s(NumberField.corner), style: .circular).fill(Theme.bgControlAlt))
                .overlay(RoundedRectangle(cornerRadius: s(NumberField.corner), style: .circular)
                    .strokeBorder(isFocused ? Theme.accent : Theme.divStrong, lineWidth: k))
                .padding(.top, s(8))
                .accessibilityLabel(Text(AccessibilityText.lyric))
                .onSubmit(advance)
                .onKeyPress(.tab, phases: .down) { _ in
                    advance()
                    return .handled
                }

            Text("End with - to carry the word on, _ to hold the syllable.")
                .font(Fonts.meta(k))
                .foregroundStyle(Theme.textMuted)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, s(6))
        }
        .padding(s(Self.padding))
        .frame(width: s(NoteCard.width))
        .popupSurface(corner: s(MenuMetrics.corner), shadow: false)
        .onAppear {
            draft = note?.lyric?.typed ?? ""
            isFocused = true
        }
        .onChange(of: model.editor.lyricNote) { _, id in
            draft = id.flatMap { model.document?.note($0)?.note.lyric?.typed } ?? ""
            isFocused = true
        }
    }

    /// "Lyric · E4 at 3.2": which note the syllable goes on.
    private func header(_ note: NoteEvent?) -> String {
        guard let note else { return "Lyric" }

        return "Lyric · \(TimeFormat.pitchName(note.pitch)) at \(model.editor.grid.barBeatLabel(at: note.startTime + 1e-6))"
    }

    private func advance() {
        model.commitLyricEntry(draft)
    }
}
