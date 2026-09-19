import NeuralSheetCore
import SwiftUI

/// File → Export MIDI… (⇧⌘E): the export's two settings -- the tempo the file is written at and
/// what the writer does with more instruments than the file has channels -- confirmed before the
/// save panel opens. A sheet on the main window, on system controls like the Settings window.
///
/// The fields start from what is stored (the tempo in the session, the overflow mode in the
/// global settings) and write back on Export…, so the Drag MIDI out button, which has no dialog
/// of its own, uses whatever was last confirmed here.
struct ExportDialog: View {
    let model: AppModel

    @Environment(\.dismiss) private var dismiss
    @State private var tempoText = ""
    @State private var overflowMode: MidiOverflowMode = .reuseChannels

    static let minTempo = TempoGrid.minBpm
    static let maxTempo = TempoGrid.maxBpm
    static let defaultTempo = TempoGrid.defaultBpm

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Form {
                Section {
                    LabeledContent("Tempo") {
                        HStack(spacing: 6) {
                            TextField("120", text: $tempoText)
                                .textFieldStyle(.roundedBorder)
                                .multilineTextAlignment(.trailing)
                                .frame(width: 72)
                                .onSubmit(export)

                            Text("BPM")
                                .foregroundStyle(.secondary)
                        }
                    }
                } footer: {
                    Text("The tempo the MIDI file is written at; the notes keep their timing in seconds.")
                        .foregroundStyle(.secondary)
                }

                Section {
                    Picker("When there are too many instruments:", selection: $overflowMode) {
                        Text("Reuse the last channels").tag(MidiOverflowMode.reuseChannels)
                        Text("Drop the extra instruments").tag(MidiOverflowMode.dropExtraInstruments)
                    }
                    .pickerStyle(.radioGroup)
                } footer: {
                    Text("A MIDI file has 16 channels, one of which is reserved for drums.")
                        .foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)

            HStack {
                Spacer()

                Button("Cancel", role: .cancel) {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)

                Button("Export…", action: export)
                    .keyboardShortcut(.defaultAction)
            }
            .padding([.horizontal, .bottom], 20)
        }
        .frame(width: 460)
        .onAppear {
            tempoText = Self.format(model.exportTempo)
            overflowMode = model.settings.midiOverflowMode
        }
    }

    /// Writes the settings back, closes the sheet, and opens the save panel a turn later, once
    /// the sheet has gone: a panel run while the sheet is still up would stack on it.
    private func export() {
        model.exportTempo = Self.tempo(from: tempoText)
        model.settings.midiOverflowMode = overflowMode
        dismiss()

        DispatchQueue.main.async {
            model.exportMidi()
        }
    }

    /// The rule the toolbar's field had (`NumericTextEditor<double>`): empty is the default,
    /// anything else is clamped into 20…999 -- `TempoGrid`'s rule, which the grid's BPM shares.
    static func tempo(from text: String) -> Double {
        TempoGrid.clampedBpm(Double(text.trimmingCharacters(in: .whitespaces)) ?? .nan)
    }

    /// Whole numbers without a decimal point, anything else as typed.
    static func format(_ tempo: Double) -> String {
        tempo == tempo.rounded() ? String(Int(tempo)) : String(tempo)
    }
}
