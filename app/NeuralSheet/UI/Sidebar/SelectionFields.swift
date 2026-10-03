import AppKit
import NeuralSheetCore
import SwiftUI

/// The rows that set the selection (design §6.3): instrument, start, length, pitch, velocity
/// and the lyric (markers and lyrics design §2), then two read-only rows, confidence (confidence design §2) and the largest pitch
/// curve deviation (pitch curves design §2). Every commit is one batch
/// over the whole selection; a field whose notes disagree shows "—". The sidebar's inspector and
/// the roll's note card both show these.
///
/// A change the ear can tell -- instrument, pitch, velocity -- sounds the first selected note
/// once it has landed, so a value can be found by listening.
struct SelectionFields: View {
    let model: AppModel
    /// The popup these fields are inside, if any: the instrument menu is then shown as its
    /// child, without taking key, or the popup would close under it.
    var host: PopupMenuPresenter? = nil

    @Environment(\.uiScale) private var k
    @State private var instrumentMenu = PopupMenuPresenter()
    @State private var instrumentAnchor: NSView?
    /// The velocity the fader is being dragged to, committed as one batch when the drag ends.
    @State private var draftVelocity: Int?

    static let rowHeight: CGFloat = 22
    static let rowGap: CGFloat = 2

    /// The selected notes, in document order.
    private var selected: [NoteEvent] {
        guard let document = model.document else { return [] }

        let ids = model.editor.selection

        return document.notes.filter { ids.contains($0.id) }.map(\.note)
    }

    var body: some View {
        let s = Scaled(k: k)
        let notes = selected
        let enabled = !notes.isEmpty

        VStack(spacing: s(Self.rowGap)) {
            row("Instrument") { instrumentControl(notes: notes) }
            row("Start") {
                NumberField(value: shared(notes.map(\.startTime)) ?? (notes.isEmpty ? 0 : nil), range: 0 ... 36_000,
                            decimals: 3, step: 0.01, width: 72) { value in
                    commit { $0.setStart(model.editor.selection, seconds: value) }
                }
                .accessibilityLabel(Text(AccessibilityText.noteStart))
            }
            row("Length") {
                NumberField(value: shared(notes.map { $0.endTime - $0.startTime }) ?? (notes.isEmpty ? 0 : nil),
                            range: NoteDocument.minimumLength ... 3_600, decimals: 3, step: 0.01, width: 72) { value in
                    commit { $0.setLength(model.editor.selection, seconds: value) }
                }
                .accessibilityLabel(Text(AccessibilityText.noteLength))
            }
            row("Pitch") { pitchControl(notes: notes) }
            row("Velocity") { velocityControl(notes: notes) }
            row("Lyric") {
                // One note's syllable at a time: words are entered note by note, so a selection
                // of several shows "—" and the field waits for one.
                LyricField(text: notes.count == 1 ? notes[0].lyric?.typed ?? "" : (notes.isEmpty ? "" : "—"),
                           width: s(120), scale: k) { model.setSelectedLyric($0) }
                    .disabled(notes.count != 1)
                    .accessibilityLabel(Text(AccessibilityText.lyric))
            }
            row("Confidence") {
                Text(SelectionText.confidence(notes))
                    .font(Fonts.mono(10, weight: 500, scale: k))
                    .foregroundStyle(Theme.textStrong)
                    .padding(.horizontal, s(6))
                    .accessibilityLabel(Text(AccessibilityText.confidence))
                    .accessibilityValue(Text(verbatim: SelectionText.confidence(notes)))
            }
            row("Pitch curve") {
                Text(SelectionText.pitchCurve(notes))
                    .font(Fonts.mono(10, weight: 500, scale: k))
                    .foregroundStyle(Theme.textStrong)
                    .padding(.horizontal, s(6))
                    .accessibilityLabel(Text(AccessibilityText.pitchCurve))
                    .accessibilityValue(Text(verbatim: SelectionText.pitchCurve(notes)))
            }
        }
        .disabled(!enabled)
        .opacity(enabled ? 1 : Theme.disabledAlpha)
    }

    // MARK: - Rows

    /// The label is spoken by the control beside it, so VoiceOver reads it once (a11y design §2).
    private func row<Control: View>(_ label: LocalizedStringKey, @ViewBuilder control: () -> Control) -> some View {
        let s = Scaled(k: k)

        return HStack(spacing: 0) {
            Text(label)
                .font(Fonts.meta(k))
                .foregroundStyle(Theme.textMuted)
                .accessibilityHidden(true)

            Spacer(minLength: 0)

            control()
        }
        .frame(height: s(Self.rowHeight))
    }

    private func mixed<T: Equatable>(_ values: [T]) -> Bool {
        guard let first = values.first else { return false }

        return values.contains { $0 != first }
    }

    /// The one value every note has, or nil when the selection is empty or disagrees.
    private func shared<T: Equatable>(_ values: [T]) -> T? {
        mixed(values) ? nil : values.first
    }

    /// One batch on the document, through the model; `audible` sounds the result.
    private func commit(audible: Bool = false, _ build: (NoteDocument) -> EditBatch) {
        guard let document = model.document else { return }

        model.commit(build(document))

        if audible {
            model.auditionSelection()
        }
    }

    // MARK: - Instrument

    private func instrumentControl(notes: [NoteEvent]) -> some View {
        let s = Scaled(k: k)
        let programs = notes.map(\.program)
        let title = programs.isEmpty || mixed(programs) ? "—" : Instruments.info(forProgram: programs[0]).localizedName

        return FlatButton(idle: Theme.bgControlAlt, on: Theme.bgControlActive,
                          foregroundIdle: Theme.textButton, foregroundOn: Theme.textBright,
                          corner: s(NumberField.corner), action: showInstrumentMenu) { _ in
            Text(title)
                .font(Fonts.meta(k))
                .lineLimit(1)
                .frame(width: s(120), height: s(NumberField.height), alignment: .leading)
                .padding(.horizontal, s(6))
        }
        .background(AnchorCatcher { instrumentAnchor = $0 })
        .accessibilityLabel(Text(AccessibilityText.instrument))
        .accessibilityValue(Text(verbatim: title))
    }

    private func showInstrumentMenu() {
        guard let anchor = instrumentAnchor else { return }

        let model = model

        InstrumentPicker.show(instrumentMenu, from: anchor, host: host, model: model,
                              current: Set(selected.map(\.program)), scale: k) { program in
            model.setSelectionProgram(program)
        }
    }

    // MARK: - Velocity

    /// The fader stages its value while dragging and commits once when the drag ends, so a drag is
    /// one undo step; the field beside it shows the draft while there is one.
    private func velocityControl(notes: [NoteEvent]) -> some View {
        let s = Scaled(k: k)
        let velocities = notes.map(\.velocity)
        let shown = shared(velocities) ?? (velocities.isEmpty ? 100 : nil)
        // A disagreeing selection puts the thumb at the mean, so a drag moves every note from there.
        let mean = velocities.isEmpty ? 100 : Int((Double(velocities.reduce(0, +)) / Double(velocities.count)).rounded())

        return HStack(spacing: s(6)) {
            PillSlider(value: Binding(get: { Double(draftVelocity ?? shown ?? mean) },
                                      set: { draftVelocity = Int($0) }),
                       range: 1 ... 127, step: 1, width: s(60),
                       fill: Theme.accent.opacity(0.85), track: Theme.faderTrack, thumb: Theme.faderThumb,
                       onDoubleClick: {
                           draftVelocity = nil
                           commit(audible: true) { $0.setVelocity(model.editor.selection, velocity: 100) }
                       },
                       onDragEnded: {
                           guard let velocity = draftVelocity else { return }

                           draftVelocity = nil
                           commit(audible: true) { $0.setVelocity(model.editor.selection, velocity: velocity) }
                       },
                       valueText: (draftVelocity ?? shown).map(String.init) ?? "—")
                .accessibilityLabel(Text(AccessibilityText.velocity))

            NumberField(value: (draftVelocity ?? shown).map(Double.init), range: 1 ... 127, decimals: 0, width: 40) { value in
                commit(audible: true) { $0.setVelocity(model.editor.selection, velocity: Int(value)) }
            }
            .accessibilityLabel(Text(AccessibilityText.velocity))
        }
        // A drag the system cancelled never ends; the next selection must not inherit its draft.
        .onChange(of: model.editor.selection) { _, _ in draftVelocity = nil }
    }

    // MARK: - Pitch

    private func pitchControl(notes: [NoteEvent]) -> some View {
        let s = Scaled(k: k)
        let pitches = notes.map(\.pitch)

        return PitchField(text: pitches.isEmpty || mixed(pitches) ? "—" : TimeFormat.pitchName(pitches[0]), width: s(72), scale: k) { pitch in
            commit(audible: true) { $0.setPitch(model.editor.selection, pitch: pitch) }
        }
        .accessibilityLabel(Text(AccessibilityText.pitch))
    }
}

/// The lyric field (markers and lyrics design §2): the syllable as the lyric card shows it, a
/// trailing "-" carrying the word on and "_" holding it. Return or the focus leaving commits;
/// Return gives the keyboard back, as the pitch field does.
struct LyricField: View {
    let text: String
    let width: CGFloat
    let scale: CGFloat
    let onCommit: (String) -> Void

    @State private var draft = ""
    @FocusState private var isFocused: Bool

    var body: some View {
        TextField(String(), text: $draft)
            .textFieldStyle(.plain)
            .font(Fonts.meta(scale))
            .foregroundStyle(Theme.textStrong)
            .focused($isFocused)
            .padding(.horizontal, 6 * scale)
            .frame(width: width, height: NumberField.height * scale)
            .background(RoundedRectangle(cornerRadius: NumberField.corner * scale, style: .circular).fill(Theme.bgControlAlt))
            .overlay(RoundedRectangle(cornerRadius: NumberField.corner * scale, style: .circular)
                .strokeBorder(isFocused ? Theme.accent : Theme.divStrong, lineWidth: scale))
            .onAppear { draft = text }
            .onChange(of: text) { _, new in if !isFocused { draft = new } }
            .onChange(of: isFocused) { _, focused in if !focused { commit() } }
            .onSubmit { isFocused = false }
    }

    /// The focus loss Return causes commits once; an unchanged entry commits nothing.
    private func commit() {
        guard draft != text else { return }

        onCommit(draft)
    }
}

/// A note-name field: accepts `C#4`, `Db4` or a MIDI number. Return commits and gives the
/// keyboard back, so Space is the transport's again. Shared with the strip card's Split field.
struct PitchField: View {
    let text: String
    let width: CGFloat
    let scale: CGFloat
    let onCommit: (Int) -> Void

    @State private var draft = ""
    @State private var lastCommitted: Int?
    @FocusState private var isFocused: Bool

    var body: some View {
        TextField(String(), text: $draft)
            .textFieldStyle(.plain)
            .font(Fonts.mono(10, weight: 500, scale: scale))
            .foregroundStyle(Theme.textStrong)
            .multilineTextAlignment(.trailing)
            .focused($isFocused)
            .padding(.horizontal, 6 * scale)
            .frame(width: width, height: NumberField.height * scale)
            .background(RoundedRectangle(cornerRadius: NumberField.corner * scale, style: .circular).fill(Theme.bgControlAlt))
            .overlay(RoundedRectangle(cornerRadius: NumberField.corner * scale, style: .circular)
                .strokeBorder(isFocused ? Theme.accent : Theme.divStrong, lineWidth: scale))
            .onAppear { draft = text }
            .onChange(of: text) { _, new in
                lastCommitted = nil

                if !isFocused { draft = new }
            }
            .onChange(of: isFocused) { _, focused in if !focused { commit() } }
            .onSubmit {
                commit()
                isFocused = false
            }
    }

    /// Return and the focus loss it causes both come through here; the second sees the same
    /// entry and commits nothing more.
    private func commit() {
        if let pitch = SelectionText.parsePitch(draft) {
            if pitch != lastCommitted {
                lastCommitted = pitch
                onCommit(pitch)
            }
        } else {
            draft = text
        }
    }
}
