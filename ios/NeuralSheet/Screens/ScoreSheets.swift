import NeuralSheetCore
import SwiftUI

/// A part's display (arrangement design §6), the Mac's part card as a form: opened by a tap on
/// the part's name in the score. The display mode, the clef, the transposition, the tab
/// template, tuning and frets, and the hide switch; every change goes straight to the model.
struct PartDisplaySheet: View {
    let model: MobileModel
    let program: Int

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let display = model.arrangement.display(for: program)
        // Drums have no tab and are notation whatever the mode (`ScoreDocument.build`), so the
        // Display and Tab rows, which could only switch them away from it, are not offered.
        let isDrums = program == NoteEvent.drumProgram

        NavigationStack {
            Form {
                Section {
                    if !isDrums {
                        Picker(String(localized: "Display", comment: "Shown in the Score tab's part card"), selection: binding(display.mode) { model.setPartMode($0, program: program) }) {
                            ForEach(PartDisplay.Mode.allCases, id: \.self) { mode in
                                Text(verbatim: mode.localizedName).tag(mode)
                            }
                        }
                        .pickerStyle(.segmented)
                        .accessibilityIdentifier("part.mode")
                    }

                    Picker(String(localized: "Clef", comment: "Accessibility label: the part card's clef button"), selection: binding(display.clef) { model.setPartClef($0, program: program) }) {
                        ForEach(ClefChoice.allCases, id: \.self) { clef in
                            Text(verbatim: clef.localizedName).tag(clef)
                        }
                    }
                }

                Section {
                    Picker(String(localized: "Transposition", comment: "Accessibility label: the part card's transposition preset button"), selection: binding(display.transposition) { model.setPartTransposition($0, program: program) }) {
                        ForEach(transpositions(including: display.transposition), id: \.1) { preset in
                            Text(verbatim: preset.0).tag(preset.1)
                        }
                    }

                    Stepper(value: binding(display.transposition) { model.setPartTransposition($0, program: program) }, in: -36 ... 36) {
                        Text(verbatim: semitones(display.transposition))
                            .monospacedDigit()
                    }
                    .accessibilityLabel(Text(AccessibilityText.transpositionSemitones))
                    .accessibilityValue(Text(verbatim: semitones(display.transposition)))
                }

                if !isDrums {
                    tabSection(display)
                }

                Section {
                    Toggle(String(localized: "Hidden", comment: "Accessibility label: the part card's hide switch"), isOn: binding(display.isHidden) { model.setPartHidden($0, program: program) })
                        .accessibilityIdentifier("part.hidden")
                }
            }
            .navigationTitle(Text(verbatim: Instruments.info(forProgram: program).localizedName))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(String(localized: "Done", comment: "Score sheets: close the sheet")) { dismiss() }
                }
            }
        }
    }

    @ViewBuilder
    private func tabSection(_ display: PartDisplay) -> some View {
        Section {
            Picker(String(localized: "Tab", comment: "Accessibility label: the part card's tablature instrument button"), selection: binding(display.tab?.template) { id in
                if let id, let template = TabTemplate.template(id: id) {
                    model.setPartTab(template: template, preset: template.presets[0], program: program)
                } else {
                    model.clearPartTab(program: program)
                }
            }) {
                Text(verbatim: PartDisplayText.none).tag(String?.none)
                ForEach(TabTemplate.all) { template in
                    Text(verbatim: template.localizedName).tag(Optional(template.id))
                }
            }
            .accessibilityIdentifier("part.tab")

            if let tab = display.tab, let template = TabTemplate.template(id: tab.template) {
                Picker(String(localized: "Tuning", comment: "Accessibility label: the part card's tuning preset button"), selection: binding(tab.presetName) { name in
                    if let preset = template.presets.first(where: { $0.name == name }) {
                        model.setPartTab(template: template, preset: preset, program: program)
                    }
                }) {
                    if tab.presetName == nil {
                        Text(verbatim: PartDisplayText.custom).tag(String?.none)
                    }

                    ForEach(template.presets, id: \.name) { preset in
                        Text(verbatim: preset.localizedName).tag(Optional(preset.name))
                    }
                }

                // One row per string, the top string first as a guitarist reads them.
                ForEach(Array(tab.tuning.enumerated()).reversed(), id: \.offset) { string, pitch in
                    Stepper(value: binding(pitch) { model.setPartTuning(string: string, pitch: $0, program: program) }, in: 0 ... 127) {
                        LabeledContent {
                            Text(verbatim: TimeFormat.pitchName(pitch))
                                .monospacedDigit()
                        } label: {
                            Text(verbatim: String(localized: "String \(tab.tuning.count - string)",
                                                  comment: "Part sheet: one string's open pitch, the top string being 1"))
                        }
                    }
                }

                Stepper(value: binding(tab.frets) { model.setPartFrets($0, program: program) }, in: 1 ... 36) {
                    LabeledContent(String(localized: "Frets", comment: "Accessibility label: the part card's fret count field")) {
                        Text(tab.frets, format: .number)
                            .monospacedDigit()
                    }
                }
            }
        }
    }

    // MARK: - Pieces

    /// A binding that reads the model's value and sends a change through `set`.
    private func binding<Value>(_ value: Value, set: @escaping (Value) -> Void) -> Binding<Value> {
        Binding(get: { value }, set: set)
    }

    /// The presets, with the part's own transposition as Custom when it is none of them.
    private func transpositions(including value: Int) -> [(String, Int)] {
        let presets = PartDisplayText.transpositionPresets

        return presets.contains { $0.1 == value } ? presets : presets + [(PartDisplayText.custom, value)]
    }

    private func semitones(_ value: Int) -> String {
        String(localized: "\(value) semitones", comment: "Part sheet: the transposition in semitones, e.g. \"-12 semitones\"")
    }
}

/// The score's layout and the sheet's title block (arrangement design §6): the Score toolbar's
/// Continuous / Pages and page size, first, and the Mac's Sheet card, as a form. The text fields are
/// committed when they are submitted and when the sheet closes, so typing a title is one change;
/// the switches and pickers go straight to the model.
struct ScoreSheetForm: View {
    let model: MobileModel

    @Environment(\.dismiss) private var dismiss
    @State private var draft = SheetMetadata()
    @State private var hasDraft = false

    var body: some View {
        let arrangement = model.arrangement

        NavigationStack {
            Form {
                Section {
                    Picker(String(localized: "Layout", comment: "Score sheet: continuous or pages"),
                           selection: Binding(get: { arrangement.layout }, set: { model.setScoreLayout($0) })) {
                        Text(String(localized: "Continuous", comment: "Score toolbar: the systems in one column")).tag(ScoreLayoutMode.continuous)
                        Text(String(localized: "Pages", comment: "Score toolbar: the systems on printed pages")).tag(ScoreLayoutMode.pages)
                    }
                    .pickerStyle(.segmented)
                    .accessibilityIdentifier("sheet.layout")

                    Picker(String(localized: "Page size", comment: "Score sheet: A4 or Letter"),
                           selection: Binding(get: { arrangement.pageSize }, set: { model.setPageSize($0) })) {
                        ForEach(PageSize.allCases, id: \.self) { size in
                            Text(verbatim: size.localizedName).tag(size)
                        }
                    }
                }

                Section {
                    // The title's placeholder is what the header prints without one: the take's
                    // name, or "Untitled".
                    field(String(localized: "Title", comment: "Score sheet: the title field"), text: Binding(get: { draft.title ?? "" }, set: { draft.title = $0 }),
                          prompt: CoreNames.localized(SheetMetadata().resolvedTitle(takeName: model.droppedFileName)))
                    field(String(localized: "Subtitle", comment: "Score sheet: the subtitle field"), text: $draft.subtitle)
                    field(String(localized: "Composer", comment: "Score sheet: the composer field"), text: $draft.composer)
                    field(String(localized: "Arranger", comment: "Score sheet: the arranger field"), text: $draft.arranger)
                    field(String(localized: "Copyright", comment: "Score sheet: the copyright field"), text: $draft.copyright)
                }

                Section {
                    toggle(String(localized: "Measure numbers", comment: "Score sheet: show the measure numbers"), \.showsMeasureNumbers)
                    toggle(String(localized: "Part names", comment: "Score sheet: show the part names"), \.showsPartNames)
                    toggle(String(localized: "Tempo mark", comment: "Score sheet: show the tempo mark"), \.showsTempo)
                    toggle(String(localized: "Show chords", comment: "Score sheet: show the chord symbols"), \.showsChords)
                }
            }
            .navigationTitle(Text("Sheet", comment: "Score sheet: its title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(String(localized: "Done", comment: "Score sheets: close the sheet")) { dismiss() }
                }
            }
        }
        .onAppear {
            if !hasDraft {
                draft = model.arrangement.sheet
                hasDraft = true
            }
        }
        .onDisappear(perform: commit)
    }

    /// The draft to the model, the title blank meaning the take's name.
    private func commit() {
        var sheet = model.arrangement.sheet
        sheet.title = draft.title.flatMap { $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : $0 }
        sheet.subtitle = draft.subtitle
        sheet.composer = draft.composer
        sheet.arranger = draft.arranger
        sheet.copyright = draft.copyright
        model.setSheet(sheet)
    }

    private func field(_ label: String, text: Binding<String>, prompt: String = "") -> some View {
        LabeledContent(label) {
            TextField(label, text: text, prompt: Text(verbatim: prompt))
                .multilineTextAlignment(.trailing)
                .onSubmit(commit)
        }
    }

    /// A tick, straight to the model; the draft's texts go with it so neither undoes the other.
    private func toggle(_ label: String, _ keyPath: WritableKeyPath<SheetMetadata, Bool>) -> some View {
        Toggle(label, isOn: Binding(get: { model.arrangement.sheet[keyPath: keyPath] }, set: { on in
            commit()
            var sheet = model.arrangement.sheet
            sheet[keyPath: keyPath] = on
            model.setSheet(sheet)
        }))
    }
}
