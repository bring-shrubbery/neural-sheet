import NeuralSheetCore
import SwiftUI

/// The roll's commands menu (sub-issue F): the Mac's Edit menu for touch, over the model's
/// commands. The questions the Mac asks in alerts are asked here: By Interval… and Scale… in a
/// small sheet with a stepper, Save Version… in a text alert, and Detect and Revert confirm
/// before they throw anything away.
struct RollCommandsMenu: View {
    let model: MobileModel

    @State private var askingInterval = false
    @State private var askingVelocity = false
    @State private var askingVersionName = false
    @State private var confirmingRevert = false
    @State private var confirmingDetect = false
    @State private var semitones = 7
    @State private var percent = 100
    @State private var versionName = ""

    var body: some View {
        Menu {
            editSection
            transposeMenu
            velocityMenu
            lengthsSection
            selectionSection
            analysisSection
            versionsMenu

            Section {
                Button(role: .destructive) { confirmingRevert = true } label: {
                    Text("Revert to Transcription…", comment: "Roll commands: throw the edits away")
                }
                .disabled(!model.canRevertToTranscription)
            }
        } label: {
            Label {
                Text("Commands", comment: "Roll screen: the menu of editing commands")
            } icon: {
                Image(systemName: "ellipsis.circle")
            }
            .labelStyle(.iconOnly)
            .font(.title2)
            .frame(width: 44, height: 44)
        }
        .disabled(model.document == nil)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("commands")
        .sheet(isPresented: $askingInterval) {
            NumberSheet(title: Text("Transpose by Interval", comment: "Edit → Transpose → By Interval…: the alert's title"),
                        question: Text("Semitones to move the notes by:", comment: "Edit → Transpose → By Interval…: the alert's question"),
                        value: $semitones, range: -24...24,
                        unit: Text("semitones", comment: "Edit → Transpose → By Interval…: the unit after the field")) {
                model.transposeSelectionOrAll(semitones: semitones)
            }
        }
        .sheet(isPresented: $askingVelocity) {
            NumberSheet(title: Text("Scale Velocity", comment: "Edit → Velocity → Scale…: the alert's title"),
                        question: Text("Percentage to scale each velocity by:", comment: "Edit → Velocity → Scale…: the alert's question"),
                        value: $percent, range: 10...200, step: 5, unit: Text(verbatim: "%")) {
                model.scaleVelocity(percent: percent)
            }
        }
        .alert(Text("Save Version", comment: "Edit → Versions → Save Version…: the alert's title"), isPresented: $askingVersionName) {
            TextField(String(), text: $versionName)
            Button { model.saveVersion(named: versionName) } label: { Text("Save", comment: "Save Version: the button that saves") }
            Button(role: .cancel) {} label: { Text("Cancel", comment: "A dialog's cancel button") }
        } message: {
            Text("Save the current \(model.document?.notes.count ?? 0) notes as a version named:",
                 comment: "Edit → Versions → Save Version…: the alert's question")
        }
        .confirmationDialog(Text("Discard your edits?", comment: "Alert title: an action would lose the edits to the transcription"),
                            isPresented: $confirmingRevert, titleVisibility: .visible) {
            Button(role: .destructive) { model.revertToTranscription() } label: {
                Text("Discard", comment: "Alert button: go ahead and lose the edits")
            }
        } message: {
            Text("The transcription has been edited. Reverting to the transcription will throw the edits away.",
                 comment: "Alert body: Edit → Revert to Transcription… over edits")
        }
        .confirmationDialog(Text("Replace the tempo map?", comment: "Alert title: Detect over an edited tempo map"),
                            isPresented: $confirmingDetect, titleVisibility: .visible) {
            Button(role: .destructive) { model.detect() } label: {
                Text("Replace", comment: "Alert button: replace the edited tempo map")
            }
        } message: {
            Text("Detect replaces the tempo changes and the time signature with what it finds in the take.",
                 comment: "Alert body: Detect over an edited tempo map")
        }
    }

    // MARK: - Sections

    @ViewBuilder
    private var editSection: some View {
        Section {
            Button { model.quantizeSelectionOrAll() } label: { Text("Quantize", comment: "Roll commands: notes onto the grid") }
                .disabled(!model.canEdit)

            if model.canSnapToScale {
                Button { model.snapSelectionOrAllToScale() } label: { Text("Snap to Scale", comment: "Roll commands: notes onto the key's scale") }
            }
        }
    }

    private var transposeMenu: some View {
        Menu {
            Button { model.transposeSelectionOrAll(semitones: 1) } label: { Text("Semitone Up", comment: "Edit → Transpose") }
            Button { model.transposeSelectionOrAll(semitones: -1) } label: { Text("Semitone Down", comment: "Edit → Transpose") }
            Button { model.transposeSelectionOrAll(semitones: 12) } label: { Text("Octave Up", comment: "Edit → Transpose") }
            Button { model.transposeSelectionOrAll(semitones: -12) } label: { Text("Octave Down", comment: "Edit → Transpose") }
            Button { askingInterval = true } label: { Text("By Interval…", comment: "Edit → Transpose") }
        } label: {
            Text("Transpose", comment: "Edit menu: the Transpose submenu")
        }
        .disabled(!model.canEdit)
    }

    private var velocityMenu: some View {
        Menu {
            Button { askingVelocity = true } label: { Text("Scale…", comment: "Edit → Velocity") }
            Button { model.velocityFromAudio() } label: { Text("From Audio", comment: "Edit → Velocity") }
                .disabled(!model.canVelocityFromAudio)
        } label: {
            Text("Velocity", comment: "Edit menu: the Velocity submenu")
        }
        .disabled(!model.canEdit)
    }

    @ViewBuilder
    private var lengthsSection: some View {
        Section {
            Button { model.legatoSelectionOrAll() } label: { Text("Legato", comment: "Edit menu: each note to the next start") }
            Button { model.joinSelectionOrAll() } label: { Text("Join Notes", comment: "Edit menu: same-pitch runs joined") }
            Button { model.splitAtPlayhead() } label: { Text("Split at Playhead", comment: "Edit menu: notes the playhead crosses cut in two") }
            Button { model.humanizeSelectionOrAll() } label: { Text("Humanize", comment: "Edit menu: small random timing and velocity") }
        }
        .disabled(!model.canEdit)
    }

    @ViewBuilder
    private var selectionSection: some View {
        Section {
            Button { model.selectAll() } label: { Text("Select All", comment: "Roll commands: select every note") }
                .disabled(!model.canEdit)
            Button { model.deselectAll() } label: { Text("Deselect All", comment: "Roll commands: select nothing") }
                .disabled(model.editor.selection.isEmpty)
            Button { model.selectDoubtfulNotes() } label: { Text("Select Doubtful Notes", comment: "Edit menu: the notes the model was unsure of") }
                .disabled(!model.canSelectDoubtfulNotes)
        }
    }

    @ViewBuilder
    private var analysisSection: some View {
        Section {
            Button { model.trackPitch() } label: { Text("Track Pitch", comment: "Edit menu: measure the notes' pitch curves") }
                .disabled(!model.canTrackPitch)
            Button {
                if model.detectReplacesEdits {
                    confirmingDetect = true
                } else {
                    model.detect()
                }
            } label: {
                Text("Detect Tempo, Key and Chords", comment: "Roll commands: the Mac's Detect button")
            }
            .disabled(!model.canDetect)
        }
    }

    private var versionsMenu: some View {
        Menu {
            Button {
                versionName = model.defaultVersionName()
                askingVersionName = true
            } label: {
                Text("Save Version…", comment: "Edit → Versions")
            }

            Section {
                ForEach(model.versionRows) { row in
                    Button { model.restoreVersion(id: row.id) } label: { Text(verbatim: row.menuTitle) }
                }
            } header: {
                Text("Restore", comment: "Edit → Versions: the versions to restore")
            }

            Menu {
                Button { model.compare(with: nil) } label: {
                    if model.comparedVersion == nil {
                        Label { Text("None", comment: "Edit → Versions → Compare With: no comparison") } icon: { Image(systemName: "checkmark") }
                    } else {
                        Text("None", comment: "Edit → Versions → Compare With: no comparison")
                    }
                }

                ForEach(model.versionRows) { row in
                    Button { model.compare(with: row.id) } label: {
                        if model.comparedVersion?.id == row.id {
                            Label { Text(verbatim: row.menuTitle) } icon: { Image(systemName: "checkmark") }
                        } else {
                            Text(verbatim: row.menuTitle)
                        }
                    }
                }
            } label: {
                Text("Compare With", comment: "Edit → Versions: the version to ghost behind the roll")
            }

            Button { model.showDifferences() } label: { Text("Show Differences", comment: "Edit → Versions: select the notes the compared version lacks") }
                .disabled(model.comparedVersion == nil || !model.canEdit)
        } label: {
            Text("Versions", comment: "Edit menu: the Versions submenu")
        }
        .disabled(!model.canUseVersions)
    }
}

/// A whole number asked for with a stepper: By Interval… and Scale….
private struct NumberSheet: View {
    let title: Text
    let question: Text
    @Binding var value: Int
    let range: ClosedRange<Int>
    var step = 1
    let unit: Text
    let onApply: () -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Stepper(value: $value, in: range, step: step) {
                        HStack {
                            Text(value, format: .number).monospacedDigit()
                            unit.foregroundStyle(.secondary)
                        }
                    }
                } header: {
                    question
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button { dismiss() } label: { Text("Cancel", comment: "A dialog's cancel button") }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        onApply()
                        dismiss()
                    } label: {
                        Text("Apply", comment: "A number sheet's button that runs the command")
                    }
                }
            }
        }
        .presentationDetents([.height(220)])
    }
}
