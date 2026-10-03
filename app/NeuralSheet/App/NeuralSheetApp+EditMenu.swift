import AppKit
import NeuralSheetCore
import SwiftUI

/// The Edit menu, out of `NeuralSheetApp.swift` to keep that file focused.
extension NeuralSheetApp {
    // MARK: - Edit menu

    /// Undo/Redo and the note commands. A text field that has the keyboard keeps its own undo,
    /// select-all and delete: the actions go down the responder chain in that case, as the
    /// system items would have.
    ///
    /// Undo, Redo and Select All are always enabled and route when chosen: which responder has
    /// the keyboard is not observable, so a `disabled` that read it would go stale the moment a
    /// field took focus, and ⌘Z would be dead inside it. Outside the Edit tab, with no field
    /// focused, they do nothing; the model guards its side too. The items whose enablement is
    /// model state alone stay disabled outside the Edit tab.
    @CommandsBuilder
    func editMenu(model: AppModel) -> some Commands {
        CommandGroup(replacing: .undoRedo) {
            Button(model.undoMenuTitle) {
                if Self.textFieldHasFocus {
                    NSApp.sendAction(Selector(("undo:")), to: nil, from: nil)
                } else if model.workspace == .edit {
                    model.undo()
                }
            }
            .keyboardShortcut("z", modifiers: .command)

            Button(model.redoMenuTitle) {
                if Self.textFieldHasFocus {
                    NSApp.sendAction(Selector(("redo:")), to: nil, from: nil)
                } else if model.workspace == .edit {
                    model.redo()
                }
            }
            .keyboardShortcut("z", modifiers: [.command, .shift])
        }

        // Cut, Copy and Paste route like Undo: a field's own while one is being typed in, the
        // selection's in the Edit tab. What the pasteboard holds is not observable either, so
        // Paste stays enabled and does nothing when there are no notes on it.
        CommandGroup(replacing: .pasteboard) {
            Button("Cut") {
                if Self.textFieldHasFocus {
                    NSApp.sendAction(#selector(NSText.cut(_:)), to: nil, from: nil)
                } else if model.workspace == .edit {
                    model.cutSelection()
                }
            }
            .keyboardShortcut("x", modifiers: .command)

            Button("Copy") {
                if Self.textFieldHasFocus {
                    NSApp.sendAction(#selector(NSText.copy(_:)), to: nil, from: nil)
                } else if model.workspace == .edit {
                    model.copySelection()
                }
            }
            .keyboardShortcut("c", modifiers: .command)

            Button("Paste") {
                if Self.textFieldHasFocus {
                    NSApp.sendAction(#selector(NSText.paste(_:)), to: nil, from: nil)
                } else if model.workspace == .edit {
                    model.paste()
                }
            }
            .keyboardShortcut("v", modifiers: .command)

            Divider()

            Button("Delete") { model.deleteSelection() }
                .disabled(model.workspace != .edit || model.editor.selection.isEmpty)

            Button("Select All") {
                if Self.textFieldHasFocus {
                    NSApp.sendAction(#selector(NSText.selectAll(_:)), to: nil, from: nil)
                } else if model.workspace == .edit {
                    model.selectAll()
                }
            }
            .keyboardShortcut("a", modifiers: .command)

            Button("Deselect All") { model.deselectAll() }
                .keyboardShortcut("a", modifiers: [.command, .shift])
                .disabled(model.workspace != .edit)

            // Confidence design §2: the notes worth a look, ready for Delete.
            Button("Select Doubtful Notes") { model.selectDoubtfulNotes() }
                .keyboardShortcut("d", modifiers: [.command, .shift])
                .disabled(!model.canSelectDoubtfulNotes)

            Divider()

            Button("Quantize") { model.quantizeSelectionOrAll() }
                .keyboardShortcut("u", modifiers: .command)
                .disabled(model.workspace != .edit)

            Button("Snap to Scale") { model.snapSelectionOrAllToScale() }
                .keyboardShortcut("k", modifiers: [.command, .shift])
                .disabled(model.workspace != .edit || model.editor.key == nil)

            // Chord symbols design §2: no key, as ⇧⌘H is Humanize.
            Button("Detect Chords") { model.detectChords() }
                .disabled(model.workspace != .edit || !model.canDetectChords)

            // Pitch curves design §2: the bends and vibrato inside each note, from the audio.
            Button("Track Pitch") { model.trackPitch() }
                .keyboardShortcut("p", modifiers: [.command, .option])
                .disabled(!model.canTrackPitch)

            bulkCommands(model: model)

            Divider()

            Button("Revert to Transcription…") { model.revertToTranscription() }
                .disabled(model.workspace != .edit || !model.hasEdits)
        }
    }

    /// The bulk commands (editor commands design §2), on the selection or every note. The
    /// Transpose items carry no key: ↑ ↓ ⇧↑ ⇧↓ already nudge the selection from the roll, and as
    /// menu equivalents they would take the arrows from every field and list.
    @ViewBuilder
    private func bulkCommands(model: AppModel) -> some View {
        Menu("Transpose") {
            Button("Up a Semitone") { model.transposeSelectionOrAll(semitones: 1) }
            Button("Down a Semitone") { model.transposeSelectionOrAll(semitones: -1) }
            Button("Up an Octave") { model.transposeSelectionOrAll(semitones: 12) }
            Button("Down an Octave") { model.transposeSelectionOrAll(semitones: -12) }

            Divider()

            Button("By Interval…") { model.transposeByInterval() }
        }
        .disabled(!model.canBulkEdit)

        Menu("Velocity") {
            Button("Scale…") { model.scaleVelocityFromPrompt() }

            Button("From Audio") { model.velocityFromAudio() }
                .disabled(!model.canVelocityFromAudio)
        }
        .disabled(!model.canBulkEdit)

        Button("Legato") { model.legatoSelectionOrAll() }
            .keyboardShortcut("l", modifiers: .command)
            .disabled(!model.canBulkEdit)

        Button("Join Notes") { model.joinSelectionOrAll() }
            .keyboardShortcut("j", modifiers: .command)
            .disabled(!model.canBulkEdit)

        Button("Split at Playhead") { model.splitAtPlayhead() }
            .keyboardShortcut("t", modifiers: .command)
            .disabled(!model.canBulkEdit)

        Button("Humanize") { model.humanizeSelectionOrAll() }
            // ⇧⌘H rather than the design's ⌥⌘H, which is the app menu's Hide Others.
            .keyboardShortcut("h", modifiers: [.command, .shift])
            .disabled(!model.canBulkEdit)
    }

    /// Whether a text field is being typed in; the menu's shortcuts then belong to it.
    private static var textFieldHasFocus: Bool {
        let responder = NSApp.keyWindow?.firstResponder

        return responder is NSText || responder is NSTextField
    }
}
