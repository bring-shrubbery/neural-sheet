import NeuralSheetCore
import SwiftUI

/// The instrument strips (sub-issue H): the Mac's sidebar strips as list rows, in the iPad's
/// sidebar and the iPhone's strips sheet. Each has its name and count (a tap singles it out on
/// the roll), its meter, M and S, the fader and the pan, and a menu with the whole-instrument
/// commands: change every note to another instrument, split at a pitch, delete.
struct InstrumentStripsSection: View {
    let model: MobileModel

    @State private var splitting: SplitTarget?

    var body: some View {
        Section {
            if model.mixer.entries.isEmpty {
                Text("No instruments yet", comment: "Instrument strips: nothing transcribed or selected")
                    .foregroundStyle(.secondary)
            }

            ForEach(model.mixer.entries, id: \.program) { entry in
                InstrumentStripRow(model: model, entry: entry) {
                    splitting = SplitTarget(entry: entry)
                }
            }
        } header: {
            Text("Instruments", comment: "iPad sidebar: the take's instruments")
        }
        .sheet(item: $splitting) { target in
            SplitInstrumentSheet(model: model, entry: target.entry)
                .presentationDetents([.medium])
        }
    }
}

private struct SplitTarget: Identifiable {
    var entry: InstrumentEntry
    var id: Int { entry.program }
}

/// One strip.
private struct InstrumentStripRow: View {
    let model: MobileModel
    let entry: InstrumentEntry
    let split: () -> Void

    var body: some View {
        let program = entry.program
        let settings = model.mixer.settings[program] ?? InstrumentChannelSettings()
        let highlighted = model.highlightedProgram == program
        let colour = Color(.sRGB, red: entry.info.colour.r, green: entry.info.colour.g, blue: entry.info.colour.b,
                           opacity: entry.info.colour.a)

        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Button { model.toggleHighlight(program: program) } label: {
                    HStack(spacing: 8) {
                        RoundedRectangle(cornerRadius: 3)
                            .fill(colour)
                            .frame(width: 12, height: 12)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(entry.info.localizedName)
                                .fontWeight(highlighted ? .semibold : .regular)
                                .lineLimit(1)
                            Text(verbatim: meta)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityHint(Text("Singles the instrument out on the piano roll", comment: "VoiceOver hint (iOS instrument strip): tapping the name highlights its notes"))
                .accessibilityAddTraits(highlighted ? .isSelected : [])
                .accessibilityIdentifier("strip-\(program)")

                commandsMenu
            }

            StripMeter(model: model, program: program)
                .frame(height: 4)

            HStack(spacing: 6) {
                letterToggle("M", isOn: settings.muted, tint: .orange, id: "mute-\(program)",
                             label: Text(AccessibilityText.mute)) {
                    model.setMuted(program: program, !settings.muted)
                }
                letterToggle("S", isOn: settings.soloed, tint: .yellow, id: "solo-\(program)",
                             label: Text(AccessibilityText.solo)) {
                    model.setSoloed(program: program, !settings.soloed)
                }

                GainSlider(value: settings.gainDb, id: "fader-\(program)",
                           label: Text(AccessibilityText.level)) { db, dragging in
                    model.setGain(program: program, db: db, dragging: dragging)
                } ended: {
                    model.endMixDrag()
                }
            }

            PanSlider(value: settings.pan, id: "pan-\(program)") { pan, dragging in
                model.setPan(program: program, pan, dragging: dragging)
            } ended: {
                model.endMixDrag()
            }
        }
        .padding(.vertical, 4)
    }

    // MARK: - Pieces

    /// The Mac's strip meta: "selected · not transcribed yet", "12 hits · kit map", "40 notes · C3-G5".
    private var meta: String {
        let separator = " \u{00B7} "

        if entry.isPlaceholder {
            return String(localized: "selected", comment: "Instrument strip: an instrument chosen for the next run")
                + separator + String(localized: "not transcribed yet", comment: "Instrument strip: no notes for it yet")
        }

        if entry.program == NoteEvent.drumProgram {
            return String(localized: "\(entry.noteCount) hits", comment: "Instrument strip: how many drum hits")
                + separator + String(localized: "kit map", comment: "Instrument strip: the drums' notes name kit pieces, not pitches")
        }

        return String(localized: "\(entry.noteCount) notes", comment: "Instrument strip: how many notes")
            + separator + TimeFormat.pitchName(entry.lowestPitch) + "-" + TimeFormat.pitchName(entry.highestPitch)
    }

    private var commandsMenu: some View {
        Menu {
            Menu {
                ForEach(Instruments.all.filter { $0.program != entry.program }, id: \.program) { info in
                    Button(info.localizedName) { model.reassignInstrument(entry.program, to: info.program) }
                }
            } label: {
                Text("Change to", comment: "Instrument card: every note of the instrument to another one")
            }

            Button(action: split) {
                Text("Split…", comment: "Instrument strip menu: split the instrument at a pitch")
            }

            Button(role: .destructive) { model.deleteInstrument(entry.program) } label: {
                Text("Delete instrument", comment: "Instrument card: delete every note of the instrument")
            }
        } label: {
            Image(systemName: "ellipsis.circle")
                .frame(width: 44, height: 44)
                .accessibilityLabel(Text(AccessibilityText.instrumentCommands))
        }
        .disabled(!model.canEdit || entry.isPlaceholder)
        // A menu's button takes its name from what it holds, not from a label set on it.
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("strip-menu-\(entry.program)")
    }

    private func letterToggle(_ letter: String, isOn: Bool, tint: Color, id: String, label: Text,
                              action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(verbatim: letter)
                .font(.caption.weight(.bold))
                .frame(width: 30, height: 30)
                .background(RoundedRectangle(cornerRadius: 6).fill(isOn ? tint : Color(.tertiarySystemFill)))
                .foregroundStyle(isOn ? Color.black : Color.primary)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityValue(Text(AccessibilityText.onOff(isOn)))
        .accessibilityAddTraits(isOn ? .isSelected : [])
        .accessibilityIdentifier(id)
    }
}

/// One strip's meter, in a view of its own so only the meters redraw with the poll.
private struct StripMeter: View {
    let model: MobileModel
    let program: Int

    var body: some View {
        LevelBar(db: model.instrumentLevelDb(program: program), segments: 16)
            .accessibilityHidden(true)
    }
}

/// L … R, the centre a detent the slider snaps to near it.
private struct PanSlider: View {
    let value: Double
    let id: String
    let change: (Double, Bool) -> Void
    let ended: () -> Void

    @State private var isDragging = false

    var body: some View {
        HStack(spacing: 8) {
            Text("L", comment: "Instrument strip: the pan's left end")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Slider(value: Binding(get: { value }, set: { change(abs($0) < 0.05 ? 0 : $0, isDragging) }), in: -1 ... 1) {
                Text(AccessibilityText.panLabel)
            } onEditingChanged: { editing in
                isDragging = editing

                if !editing { ended() }
            }
            .accessibilityValue(Text(AccessibilityText.pan(value)))
            .accessibilityIdentifier(id)
            Text("R", comment: "Instrument strip: the pan's right end")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
        }
    }
}

/// Split at a pitch: the notes at or above it (or below it) to another instrument.
private struct SplitInstrumentSheet: View {
    let model: MobileModel
    let entry: InstrumentEntry

    @Environment(\.dismiss) private var dismiss
    @State private var pitch: Int
    @State private var sendingAbove = true
    @State private var destination: Int?

    init(model: MobileModel, entry: InstrumentEntry) {
        self.model = model
        self.entry = entry
        // The midpoint of the part's range, rounded down, as the Mac's card starts.
        _pitch = State(initialValue: (entry.lowestPitch + entry.highestPitch) / 2)
    }

    var body: some View {
        NavigationStack {
            Form {
                Stepper(value: $pitch, in: 0 ... 127) {
                    LabeledContent {
                        Text(verbatim: TimeFormat.pitchName(pitch)).monospacedDigit()
                    } label: {
                        Text("Split at", comment: "Instrument card: the pitch the split is made at")
                    }
                }

                Picker(selection: $sendingAbove) {
                    Text("Notes at or above", comment: "Split sheet: send the notes at or above the pitch").tag(true)
                    Text("Notes below", comment: "Split sheet: send the notes below the pitch").tag(false)
                } label: {
                    Text("Send", comment: "Split sheet: which side of the pitch moves")
                }

                Picker(selection: $destination) {
                    Text(verbatim: "—").tag(Int?.none)
                    ForEach(Instruments.all.filter { $0.program != entry.program }, id: \.program) { info in
                        Text(info.localizedName).tag(Int?.some(info.program))
                    }
                } label: {
                    Text("Send to", comment: "Instrument card: the instrument the split notes go to")
                }
            }
            .navigationTitle(Text(entry.info.localizedName))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button { dismiss() } label: { Text("Cancel", comment: "Closes a sheet without doing anything") }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        if let destination {
                            model.splitInstrument(entry.program, atPitch: pitch, sendingAbove: sendingAbove, to: destination)
                        }
                        dismiss()
                    } label: {
                        Text("Split", comment: "Instrument card: make the split")
                    }
                    .disabled(destination == nil)
                }
            }
        }
    }
}
