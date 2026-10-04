import NeuralSheetCore
import SwiftUI

/// The note card (sub-issue F): the Mac's `SelectionFields` for the selection -- instrument,
/// start, length, pitch, velocity, lyric, then confidence and the pitch curve read-only -- as a
/// sheet on iPhone and a popover on iPad, opened by a long press on a note or the bottom bar.
/// Every change is one batch over the whole selection through the model; a field whose notes
/// disagree shows "—". A change the ear can tell (instrument, pitch, velocity) sounds the first
/// selected note. It goes when nothing is selected any more.
struct NoteCard: View {
    let model: MobileModel

    @Environment(\.dismiss) private var dismiss
    /// The velocity the slider is being dragged to, committed as one batch when the drag ends.
    @State private var draftVelocity: Double?

    var body: some View {
        let notes = model.selectedNotes

        NavigationStack {
            Form {
                Section {
                    instrumentRow(notes)
                    secondsRow(Text("Start", comment: "Note card: the notes' start, in seconds"), field: Text(AccessibilityText.noteStart),
                               value: shared(notes.map(\.startTime)), range: 0...36_000) { model.setSelectionStart($0) }
                    secondsRow(Text("Length", comment: "Note card: the notes' length, in seconds"), field: Text(AccessibilityText.noteLength),
                               value: shared(notes.map { $0.endTime - $0.startTime }),
                               range: NoteDocument.minimumLength...3_600) { model.setSelectionLength($0) }
                    pitchRow(notes)
                    velocityRow(notes)
                    lyricRow(notes)
                }

                Section {
                    LabeledContent {
                        Text(verbatim: SelectionText.confidence(notes)).monospacedDigit()
                    } label: {
                        Text("Confidence", comment: "Note card: how sure the model was, read-only")
                    }

                    LabeledContent {
                        Text(verbatim: SelectionText.pitchCurve(notes)).monospacedDigit()
                    } label: {
                        Text("Pitch curve", comment: "Note card: the largest deviation of the notes' pitch curves, read-only")
                    }
                }

                Section {
                    Button(role: .destructive) {
                        model.deleteSelection()
                    } label: {
                        Label {
                            if notes.count == 1 {
                                Text("Delete Note", comment: "Note card: delete the selected note")
                            } else {
                                Text("Delete Notes", comment: "Note card: delete the selected notes")
                            }
                        } icon: {
                            Image(systemName: "trash")
                        }
                    }
                    .accessibilityIdentifier("card-delete")
                }
            }
            // "1 note", "3 notes", through the catalog's plural variants, as the Mac's card says it.
            .navigationTitle(Text(verbatim: SelectionText.count(notes.count)))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button { dismiss() } label: { Text("Done", comment: "Note card: close it") }
                }
            }
        }
        .frame(minWidth: 320, idealWidth: 360, minHeight: 480)
        .onChange(of: model.editor.selection) { _, selection in
            draftVelocity = nil

            if selection.isEmpty { dismiss() }
        }
        .accessibilityIdentifier("note-card")
    }

    // MARK: - Rows

    /// The instruments in the notes first, then the rest, as the Mac's picker lists them.
    private func instrumentRow(_ notes: [NoteEvent]) -> some View {
        let programs = Set(notes.map(\.program))
        let current = programs.count == 1 ? programs.first : nil
        let inUse = Set(model.timelineNotes.map(\.note.program))
        let used = inUse.sorted().map(Instruments.info(forProgram:))
        let others = Instruments.all.filter { !inUse.contains($0.program) }
        let title = current.map { Instruments.info(forProgram: $0).localizedName } ?? "—"

        return LabeledContent {
            Menu {
                if !used.isEmpty {
                    Section {
                        ForEach(used, id: \.program) { info in instrumentButton(info, current: current) }
                    } header: {
                        Text("In the Mix", comment: "Note card's instrument menu: the instruments the notes use")
                    }
                }

                Section {
                    ForEach(others, id: \.program) { info in instrumentButton(info, current: current) }
                } header: {
                    Text("All Instruments", comment: "Note card's instrument menu: every other instrument")
                }
            } label: {
                Text(verbatim: title)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(Text(AccessibilityText.instrument))
            .accessibilityValue(Text(verbatim: title))
            .accessibilityIdentifier("card-instrument")
        } label: {
            Text("Instrument", comment: "Note card: the notes' instrument")
        }
    }

    private func instrumentButton(_ info: InstrumentInfo, current: Int?) -> some View {
        Button {
            model.setSelectionProgram(info.program)
        } label: {
            if current == info.program {
                Label(info.localizedName, systemImage: "checkmark")
            } else {
                Text(info.localizedName)
            }
        }
    }

    private func secondsRow(_ label: Text, field: Text, value: Double?, range: ClosedRange<Double>,
                            commit: @escaping (Double) -> Void) -> some View {
        LabeledContent {
            CommitField(label: field, text: value.map { Formats.number($0, decimals: 3) } ?? "—", keyboard: .decimalPad) { text in
                guard let seconds = Formats.parseNumber(text), seconds.isFinite else { return false }

                commit(min(max(seconds, range.lowerBound), range.upperBound))
                return true
            }
        } label: {
            label
        }
    }

    private func pitchRow(_ notes: [NoteEvent]) -> some View {
        let pitch = shared(notes.map(\.pitch))

        return LabeledContent {
            HStack(spacing: 8) {
                CommitField(label: Text(AccessibilityText.pitch), text: pitch.map(TimeFormat.pitchName) ?? "—", keyboard: .asciiCapable) { text in
                    guard let pitch = SelectionText.parsePitch(text) else { return false }

                    model.setSelectionPitch(pitch)
                    return true
                }
                .accessibilityIdentifier("card-pitch")

                // A semitone at a time, the arrow keys' nudge.
                Stepper {
                    EmptyView()
                } onIncrement: {
                    if let pitch, pitch < 127 { model.setSelectionPitch(pitch + 1) }
                } onDecrement: {
                    if let pitch, pitch > 0 { model.setSelectionPitch(pitch - 1) }
                }
                .labelsHidden()
                .disabled(pitch == nil)
                .accessibilityLabel(Text("Pitch, a semitone at a time", comment: "VoiceOver (iOS note card): the stepper beside the pitch field"))
                .accessibilityValue(Text(verbatim: pitch.map(TimeFormat.pitchName) ?? "—"))
                .accessibilityIdentifier("card-pitch-stepper")
            }
        } label: {
            Text("Pitch", comment: "Note card: the notes' pitch")
        }
    }

    private func velocityRow(_ notes: [NoteEvent]) -> some View {
        let velocities = notes.map(\.velocity)
        let shown = shared(velocities)
        // A disagreeing selection puts the thumb at the mean, so a drag moves every note from there.
        let mean = velocities.isEmpty ? 100 : Double(velocities.reduce(0, +)) / Double(velocities.count)
        let value = draftVelocity ?? shown.map(Double.init) ?? mean.rounded()

        return LabeledContent {
            HStack {
                Slider(value: Binding(get: { value }, set: { draftVelocity = $0 }), in: 1...127, step: 1) { editing in
                    guard !editing, let velocity = draftVelocity else { return }

                    draftVelocity = nil
                    model.setSelectionVelocity(Int(velocity))
                }
                .frame(minWidth: 120)
                .accessibilityLabel(Text(AccessibilityText.velocity))
                .accessibilityValue(Text(verbatim: draftVelocity.map { String(Int($0)) } ?? shown.map(String.init) ?? "—"))
                .accessibilityIdentifier("card-velocity")

                Text(verbatim: draftVelocity.map { String(Int($0)) } ?? shown.map(String.init) ?? "—")
                    .monospacedDigit()
                    .frame(minWidth: 32, alignment: .trailing)
                    .accessibilityHidden(true)
            }
        } label: {
            Text("Velocity", comment: "Note card: the notes' velocity")
        }
    }

    /// One note's syllable at a time: a selection of several shows "—" and waits for one.
    private func lyricRow(_ notes: [NoteEvent]) -> some View {
        LabeledContent {
            CommitField(label: Text(AccessibilityText.lyric), text: notes.count == 1 ? notes[0].lyric?.typed ?? "" : "—", keyboard: .default) { text in
                model.setSelectedLyric(text)
                return true
            }
            .disabled(notes.count != 1)
        } label: {
            Text("Lyric", comment: "Note card: the note's syllable")
        }
    }

    /// The one value every note has, or nil when the selection is empty or disagrees.
    private func shared<T: Equatable>(_ values: [T]) -> T? {
        guard let first = values.first, !values.contains(where: { $0 != first }) else { return nil }

        return first
    }
}

/// A field that shows the model's value and commits what is typed on Return or when the focus
/// leaves; an entry the commit refuses goes back to the value.
private struct CommitField: View {
    /// What VoiceOver calls the field: the row's name, which the field itself does not show.
    let label: Text
    let text: String
    let keyboard: UIKeyboardType
    let onCommit: (String) -> Bool

    @State private var draft = ""
    @FocusState private var isFocused: Bool

    var body: some View {
        TextField(String(), text: $draft)
            .keyboardType(keyboard)
            .multilineTextAlignment(.trailing)
            .monospacedDigit()
            .autocorrectionDisabled()
            .textInputAutocapitalization(.never)
            .focused($isFocused)
            .frame(minWidth: 80)
            .onAppear { draft = text }
            .onChange(of: text) { _, new in if !isFocused { draft = new } }
            .onChange(of: isFocused) { _, focused in if !focused { commit() } }
            .onSubmit { isFocused = false }
            .accessibilityLabel(label)
    }

    private func commit() {
        guard draft != text else { return }

        if !onCommit(draft) {
            draft = text
        }
    }
}
