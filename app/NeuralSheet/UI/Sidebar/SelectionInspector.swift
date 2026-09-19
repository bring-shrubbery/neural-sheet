import AppKit
import NeuralSheetCore
import SwiftUI

/// The sidebar's SELECTION panel in the Edit tab (design §6.3): what is selected, and five fields
/// that set it. Every commit is one batch over the whole selection.
struct SelectionInspector: View {
    let model: AppModel

    @Environment(\.uiScale) private var k
    @State private var instrumentMenu = PopupMenuPresenter()
    @State private var instrumentAnchor: NSView?

    static let height: CGFloat = 150
    private static let paddingSide: CGFloat = 14
    private static let paddingTop: CGFloat = 12
    private static let labelHeight: CGFloat = 12
    private static let rowHeight: CGFloat = 22
    private static let rowGap: CGFloat = 2

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

        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("SELECTION")
                    .font(Fonts.sectionHeader(k))
                    .kerning(Fonts.tracking(Fonts.Tracking.sectionHeader, pointSize: Fonts.Size.sectionHeader, scale: k))
                    .foregroundStyle(Theme.textLabel)

                Spacer(minLength: 0)

                Text(countText(notes.count))
                    .font(Fonts.mono(10, weight: 400, scale: k))
                    .foregroundStyle(Theme.textFaintest)
            }
            .frame(height: s(Self.labelHeight))

            VStack(spacing: s(Self.rowGap)) {
                row("Instrument") { instrumentControl(notes: notes) }
                row("Start") {
                    NumberField(value: notes.first?.startTime ?? 0, range: 0 ... 36_000, decimals: 3, step: 0.01, width: 72) { value in
                        commit { $0.setStart(model.editor.selection, seconds: value) }
                    }
                    .opacity(mixed(notes.map(\.startTime)) ? 0.5 : 1)
                }
                row("Length") {
                    NumberField(value: notes.first.map { $0.endTime - $0.startTime } ?? 0, range: NoteDocument.minimumLength ... 3_600,
                                decimals: 3, step: 0.01, width: 72) { value in
                        commit { $0.setLength(model.editor.selection, seconds: value) }
                    }
                    .opacity(mixed(notes.map { $0.endTime - $0.startTime }) ? 0.5 : 1)
                }
                row("Pitch") { pitchControl(notes: notes) }
                row("Velocity") {
                    HStack(spacing: s(6)) {
                        // A binding, as the strips' faders have it: every drag step is one small
                        // batch, each its own undo step.
                        PillSlider(value: Binding(get: { Double(notes.first?.velocity ?? 100) },
                                                  set: { value in commit { $0.setVelocity(model.editor.selection, velocity: Int(value)) } }),
                                   range: 1 ... 127, step: 1, width: s(60),
                                   fill: Theme.accent.opacity(0.85), track: Theme.faderTrack, thumb: Theme.faderThumb,
                                   onDoubleClick: { commit { $0.setVelocity(model.editor.selection, velocity: 100) } })

                        NumberField(value: Double(notes.first?.velocity ?? 100), range: 1 ... 127, decimals: 0, width: 40) { value in
                            commit { $0.setVelocity(model.editor.selection, velocity: Int(value)) }
                        }
                    }
                }
            }
            .padding(.top, s(8))
            .disabled(!enabled)
            .opacity(enabled ? 1 : Theme.disabledAlpha)

            Spacer(minLength: 0)
        }
        .padding(.horizontal, s(Self.paddingSide))
        .padding(.top, s(Self.paddingTop))
        .frame(width: s(SidebarMetrics.stripWidth), height: s(Self.height), alignment: .topLeading)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(Theme.divSoft)
                .frame(height: k)
        }
    }

    // MARK: - Rows

    private func row<Control: View>(_ label: String, @ViewBuilder control: () -> Control) -> some View {
        let s = Scaled(k: k)

        return HStack(spacing: 0) {
            Text(label)
                .font(Fonts.meta(k))
                .foregroundStyle(Theme.textMuted)

            Spacer(minLength: 0)

            control()
        }
        .frame(height: s(Self.rowHeight))
    }

    private func countText(_ count: Int) -> String {
        switch count {
        case 0: "No selection"
        case 1: "1 note"
        default: "\(count) notes"
        }
    }

    private func mixed<T: Equatable>(_ values: [T]) -> Bool {
        guard let first = values.first else { return false }

        return values.contains { $0 != first }
    }

    /// One batch on the document, through the model.
    private func commit(_ build: (NoteDocument) -> EditBatch) {
        guard let document = model.document else { return }

        model.commit(build(document))
    }

    // MARK: - Instrument

    private func instrumentControl(notes: [NoteEvent]) -> some View {
        let s = Scaled(k: k)
        let programs = notes.map(\.program)
        let title = programs.isEmpty || mixed(programs) ? "—" : Instruments.info(forProgram: programs[0]).name

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
    }

    private func showInstrumentMenu() {
        guard let anchor = instrumentAnchor else { return }

        let menu = instrumentMenu
        let model = model
        let current = Set(selected.map(\.program))
        let titles = Instruments.all.map(\.name)
        let width = PopupMenuPresenter.width(forTitles: titles, scale: k)

        menu.show(from: anchor, width: width, scale: k) {
            ForEach(Instruments.all, id: \.program) { info in
                MenuRow(title: info.name, isTicked: current == [info.program]) {
                    menu.dismiss()
                    commit { $0.setProgram(model.editor.selection, program: info.program) }
                }
            }
        }
    }

    // MARK: - Pitch

    private func pitchControl(notes: [NoteEvent]) -> some View {
        let s = Scaled(k: k)
        let pitches = notes.map(\.pitch)

        return PitchField(text: pitches.isEmpty || mixed(pitches) ? "—" : TimeFormat.pitchName(pitches[0]), width: s(72), scale: k) { pitch in
            commit { $0.setPitch(model.editor.selection, pitch: pitch) }
        }
    }
}

/// A note-name field: accepts `C#4`, `Db4` or a MIDI number.
private struct PitchField: View {
    let text: String
    let width: CGFloat
    let scale: CGFloat
    let onCommit: (Int) -> Void

    @State private var draft = ""
    @FocusState private var isFocused: Bool

    var body: some View {
        TextField("", text: $draft)
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
            .onChange(of: text) { _, new in if !isFocused { draft = new } }
            .onChange(of: isFocused) { _, focused in if !focused { commit() } }
            .onSubmit(commit)
    }

    private func commit() {
        if let pitch = PitchField.parse(draft) {
            onCommit(pitch)
        } else {
            draft = text
        }
    }

    /// `C4`, `C#4`, `Db-1`, or `60`.
    static func parse(_ text: String) -> Int? {
        let trimmed = text.trimmingCharacters(in: .whitespaces).uppercased()

        if let number = Int(trimmed) { return (0...127).contains(number) ? number : nil }

        let names: [Character: Int] = ["C": 0, "D": 2, "E": 4, "F": 5, "G": 7, "A": 9, "B": 11]

        guard let letter = trimmed.first, var pitchClass = names[letter] else { return nil }

        var rest = trimmed.dropFirst()

        if rest.first == "#" { pitchClass += 1; rest = rest.dropFirst() }
        else if rest.first == "B", rest.count > 1 { pitchClass -= 1; rest = rest.dropFirst() }

        guard let octave = Int(rest) else { return nil }

        let midi = (octave + 1) * 12 + pitchClass

        return (0...127).contains(midi) ? midi : nil
    }
}
