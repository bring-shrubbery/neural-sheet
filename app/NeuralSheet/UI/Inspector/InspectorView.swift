import NeuralSheetCore
import SwiftUI

/// The inspector on the window's right (native chrome design §2, §4): in the Edit tab the
/// selection's fields, which the sidebar's SELECTION panel had; in every tab the grid and the key,
/// which the Edit and Score toolbars had. A standard grouped form, so it takes the system's
/// controls, type and appearance; the commands are the ones the toolbars called.
struct InspectorView: View {
    let model: AppModel

    var body: some View {
        Form {
            if model.workspace == .edit {
                Section {
                    SelectionFields(model: model)
                } header: {
                    HStack {
                        Text("Selection", comment: "Inspector: the section with the selected notes' fields")
                        Spacer()
                        Text(SelectionText.count(model.editor.selection.count))
                            .font(.system(size: 11).monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
            }

            GridSection(model: model)

            KeySection(model: model)
        }
        .formStyle(.grouped)
        .disabled(!model.canEdit)
    }
}

/// The tempo and time signature for the segment under the playhead (tempo map design §4), where
/// bar 1 starts with set-from-playhead, the swing in the Edit tab (editor commands design §2), and
/// Tap and Detect (tempo design §5).
private struct GridSection: View {
    let model: AppModel

    var body: some View {
        let editor = model.editor

        Section {
            SegmentRows(model: model)

            LabeledContent {
                HStack(spacing: 6) {
                    NumberField(value: editor.grid.offsetSeconds, range: 0 ... 36_000, decimals: 3, step: 0.01, width: 72) {
                        model.setGridOffset($0)
                    }
                    .accessibilityLabel(Text(AccessibilityText.beatOneAt))

                    Button(action: model.setGridOffsetFromPlayhead) {
                        Icons.PlayheadTargetStroked()
                            .stroke(style: Icons.strokeStyle(scale: 1))
                            .frame(width: 13, height: 13)
                    }
                    .buttonStyle(.borderless)
                    .tooltip("Set from playhead")
                    .accessibilityLabel(Text(AccessibilityText.setBeatOneFromPlayhead))
                }
            } label: {
                Text("Beat 1 at")
                    .tooltip("Where bar 1 starts, in seconds")
            }

            if model.workspace == .edit {
                swingRow(editor.grid)
            }

            HStack {
                Button("Tap", action: model.tap)
                    .tooltip("Tap in time with playback to set the tempo | t")

                Button("Detect", action: model.detectTempo)
                    .disabled(model.isDetectingTempo)
                    .tooltip("Find the tempo and its changes, the downbeat, the meter and the key")

                Spacer()
            }
        } header: {
            Text("Grid", comment: "Inspector: the section with the tempo, the time signature and the downbeat")
        }
    }

    /// 50…75 %, 50 straight; off for a division that does not swing. The score ignores swing, so
    /// it is the Edit tab's alone.
    private func swingRow(_ grid: TempoGrid) -> some View {
        let swings = TempoGrid.divisionSwings(grid.division)

        return LabeledContent {
            HStack(spacing: 4) {
                NumberField(value: (grid.swing * 100).rounded(), range: 50 ... 75, decimals: 0, width: 44) {
                    model.setSwing($0 / 100)
                }
                .accessibilityLabel(Text(AccessibilityText.swing))

                Text(verbatim: "%")
                    .foregroundStyle(.secondary)
            }
            .disabled(!swings)
        } label: {
            Text("Swing")
        }
        .tooltip("Swing: how late the second of each pair of eighths or sixteenths falls; 50 % is straight")
    }
}

/// TEMPO and TIME for the segment under the playhead: a view of its own, so following the
/// playhead redraws these and not the whole form.
private struct SegmentRows: View {
    let model: AppModel

    var body: some View {
        let segment = model.playheadSegment
        let meter = segment.timeSignature
        let rest = TimeSignature.numerators.filter { !TimeSignatureMenus.commonNumerators.contains($0) }

        LabeledContent {
            HStack(spacing: 4) {
                NumberField(value: segment.bpm, range: TempoGrid.minBpm ... TempoGrid.maxBpm, decimals: 1, width: 56) {
                    model.setGridBpm($0)
                }
                .accessibilityLabel(Text(AccessibilityText.tempo))

                Text("BPM")
                    .foregroundStyle(.secondary)
            }
        } label: {
            Text("Tempo")
        }
        .tooltip("Tempo at the playhead, in quarter notes a minute")

        LabeledContent {
            HStack(spacing: 4) {
                Picker(selection: Binding(get: { meter.numerator },
                                          set: { model.setTimeSignature(TimeSignature(numerator: $0, denominator: meter.denominator)) })) {
                    ForEach(TimeSignatureMenus.commonNumerators + rest, id: \.self) { Text(verbatim: String($0)).tag($0) }
                } label: {
                    Text(AccessibilityText.beatsInBar)
                }
                .labelsHidden()
                .fixedSize()
                .tooltip("Beats in a bar")

                Text(verbatim: "/")
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)

                Picker(selection: Binding(get: { meter.denominator },
                                          set: { model.setTimeSignature(TimeSignature(numerator: meter.numerator, denominator: $0)) })) {
                    ForEach(TimeSignatureMenus.denominators, id: \.self) { Text(verbatim: String($0)).tag($0) }
                } label: {
                    Text(AccessibilityText.beatUnit)
                }
                .labelsHidden()
                .fixedSize()
                .tooltip("The note that counts as a beat")
            }
        } label: {
            Text("Time signature", comment: "Inspector: the numerator and denominator menus")
        }
    }
}

/// The project's key (key design §5): a tonic, or none, then a mode once there is one.
private struct KeySection: View {
    let model: AppModel

    var body: some View {
        let key = model.editor.key

        Section {
            Picker(selection: Binding(get: { key?.tonic }, set: { model.setKeyTonic($0) })) {
                Text("None", comment: "Menu row: no key, or no chord bass").tag(Int?.none)

                Divider()

                ForEach(0..<12, id: \.self) { pitchClass in
                    Text(verbatim: MusicalKey.tonicMenuName(pitchClass)).tag(Int?.some(pitchClass))
                }
            } label: {
                Text("Tonic", comment: "Inspector: the key's tonic menu")
            }
            .tooltip("The project's key, or none")

            Picker(selection: Binding(get: { key?.mode ?? .major }, set: { model.setKeyMode($0) })) {
                ForEach(MusicalKey.Mode.allCases, id: \.self) { mode in
                    Text(verbatim: mode.localizedTitle).tag(mode)
                }
            } label: {
                Text("Mode")
            }
            .disabled(key == nil)
            .tooltip("Major or minor")
        } header: {
            Text("Key")
        }
    }
}
