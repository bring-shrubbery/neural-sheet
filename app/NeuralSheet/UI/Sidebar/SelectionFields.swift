import AppKit
import NeuralSheetCore
import SwiftUI

/// The five rows that set the selection (design §6.3): instrument, start, length, pitch and
/// velocity. Every commit is one batch over the whole selection; a field whose notes disagree
/// shows "—". The sidebar's inspector and the roll's note card both show these.
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
            }
            row("Length") {
                NumberField(value: shared(notes.map { $0.endTime - $0.startTime }) ?? (notes.isEmpty ? 0 : nil),
                            range: NoteDocument.minimumLength ... 3_600, decimals: 3, step: 0.01, width: 72) { value in
                    commit { $0.setLength(model.editor.selection, seconds: value) }
                }
            }
            row("Pitch") { pitchControl(notes: notes) }
            row("Velocity") { velocityControl(notes: notes) }
        }
        .disabled(!enabled)
        .opacity(enabled ? 1 : Theme.disabledAlpha)
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

    static func countText(_ count: Int) -> String {
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

    /// The instruments already in the mix first, with their colours, so moving notes onto a
    /// strip that exists is one look away; then everything else.
    private func showInstrumentMenu() {
        guard let anchor = instrumentAnchor, let window = anchor.window else { return }

        let menu = instrumentMenu
        let model = model
        let current = Set(selected.map(\.program))
        let inMix = model.mixer.entries.map(\.info)
        let inMixPrograms = Set(inMix.map(\.program))
        let others = Instruments.all.filter { !inMixPrograms.contains($0.program) }
        let titles = Instruments.all.map(\.name)
        let width = PopupMenuPresenter.width(forTitles: titles, scale: k)

        func row(_ info: InstrumentInfo, chip: Color?) -> MenuRow {
            MenuRow(title: info.name, isTicked: current == [info.program], chip: chip) {
                menu.dismiss()
                model.setSelectionProgram(info.program)
            }
        }

        let target = window.convertToScreen(anchor.convert(anchor.bounds, to: nil))

        // Inside a popup the menu is its child: it must not take key, or the popup closes.
        host?.child = menu
        menu.show(targetScreenRect: target, in: window, width: width, scale: k, placement: .alignedToTarget,
                  becomesKey: host == nil) {
            if !inMix.isEmpty {
                MenuSectionLabel(title: "IN THE MIX")

                ForEach(inMix, id: \.program) { info in
                    row(info, chip: Color(info.colour))
                }

                MenuSeparator()
                MenuSectionLabel(title: "ALL INSTRUMENTS")
            }

            ForEach(others, id: \.program) { info in
                row(info, chip: nil)
            }
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
                       })

            NumberField(value: (draftVelocity ?? shown).map(Double.init), range: 1 ... 127, decimals: 0, width: 40) { value in
                commit(audible: true) { $0.setVelocity(model.editor.selection, velocity: Int(value)) }
            }
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
    }
}

/// A note-name field: accepts `C#4`, `Db4` or a MIDI number. Return commits and gives the
/// keyboard back, so Space is the transport's again.
private struct PitchField: View {
    let text: String
    let width: CGFloat
    let scale: CGFloat
    let onCommit: (Int) -> Void

    @State private var draft = ""
    @State private var lastCommitted: Int?
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
        if let pitch = PitchField.parse(draft) {
            if pitch != lastCommitted {
                lastCommitted = pitch
                onCommit(pitch)
            }
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

private extension Color {
    /// The model's colour type as SwiftUI's, for the picker's chips. File scope, as the strip
    /// keeps its own copy: two visible overloads would collide.
    init(_ rgba: NeuralSheetCore.RGBA) {
        self.init(.sRGB, red: rgba.r, green: rgba.g, blue: rgba.b, opacity: rgba.a)
    }
}
