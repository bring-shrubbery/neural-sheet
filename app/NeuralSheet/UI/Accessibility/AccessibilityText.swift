import Foundation
import NeuralSheetCore

/// What VoiceOver says that the screen does not (a11y design §2): the names of icon-only
/// controls, the states a glyph or a fill shows, and the values a fader or a readout draws. In
/// one place so each is written, commented for its translators, and localized once. A control
/// whose own text names it -- "Quantize", "Re-transcribe" -- needs nothing from here.
///
/// Computed rather than stored, so each reading is made in the language in effect.
enum AccessibilityText {
    // MARK: - States

    static func onOff(_ isOn: Bool) -> LocalizedStringResource {
        isOn
            ? LocalizedStringResource("On", comment: "Accessibility value: a toggle button that is on")
            : LocalizedStringResource("Off", comment: "Accessibility value: a toggle button that is off")
    }

    static var ticked: LocalizedStringResource {
        LocalizedStringResource("ticked", comment: "Accessibility value: a menu row or switch whose box is ticked")
    }

    static var unticked: LocalizedStringResource {
        LocalizedStringResource("unticked", comment: "Accessibility value: a menu row or switch whose box is empty")
    }

    static func percent(_ value: Int) -> LocalizedStringResource {
        LocalizedStringResource("\(value) percent", comment: "Accessibility value: a percentage, e.g. a speed or a progress")
    }

    static func decibels(_ db: Double) -> LocalizedStringResource {
        let number = db.formatted(.number.precision(.fractionLength(1)))

        return LocalizedStringResource("\(number) dB", comment: "Accessibility value: a level in decibels, e.g. \"-6.0 dB\"")
    }

    // MARK: - Transport (top bar)

    static var goToStart: LocalizedStringResource {
        LocalizedStringResource("Go to start", comment: "Accessibility label: the top bar's button that moves the playhead to the start")
    }

    static var play: LocalizedStringResource {
        LocalizedStringResource("Play", comment: "Accessibility label: the top bar's play button while stopped")
    }

    static var pause: LocalizedStringResource {
        LocalizedStringResource("Pause", comment: "Accessibility label: the top bar's play button while playing")
    }

    static var playing: LocalizedStringResource {
        LocalizedStringResource("Playing", comment: "Accessibility value: the transport is playing")
    }

    static var stopped: LocalizedStringResource {
        LocalizedStringResource("Stopped", comment: "Accessibility value: the transport is not playing")
    }

    static var loop: LocalizedStringResource {
        LocalizedStringResource("Loop", comment: "Accessibility label: the top bar's loop button")
    }

    static var centrePlayhead: LocalizedStringResource {
        LocalizedStringResource("Center playhead", comment: "Accessibility label: the top bar's button that keeps the playhead in view")
    }

    static var record: LocalizedStringResource {
        LocalizedStringResource("Record", comment: "Accessibility label: the top bar's record button")
    }

    /// Recording, counting in, or nothing while idle.
    static func recordState(_ state: AppState) -> LocalizedStringResource {
        switch state {
        case .recording: LocalizedStringResource("Recording", comment: "Accessibility value: the record button while a take is recorded")
        case .countingIn: LocalizedStringResource("Counting in", comment: "Accessibility value: the record button while the count-in plays")
        default: LocalizedStringResource("Not recording", comment: "Accessibility value: the record button while idle")
        }
    }

    static var position: LocalizedStringResource {
        LocalizedStringResource("Position", comment: "Accessibility label: the top bar's time readout")
    }

    static func positionValue(_ position: String, of total: String) -> LocalizedStringResource {
        LocalizedStringResource("\(position) of \(total)", comment: "Accessibility value: the playhead's time of the take's length, e.g. \"0:12.34 of 3:05.00\"")
    }

    static var playbackSpeed: LocalizedStringResource {
        LocalizedStringResource("Playback speed", comment: "Accessibility label: the top bar's SPEED slider")
    }

    // MARK: - Toolbars

    static var clear: LocalizedStringResource {
        LocalizedStringResource("Clear", comment: "Accessibility label: the Transcribe toolbar's bin button")
    }

    static var clearTranscriptionOnly: LocalizedStringResource {
        LocalizedStringResource("Clear transcription only", comment: "Accessibility action on the bin button: the right-click menu's second choice")
    }

    static var exportMIDI: LocalizedStringResource {
        LocalizedStringResource("Export MIDI", comment: "Accessibility label: the toolbar's MIDI chip, which exports the MIDI file when pressed")
    }

    static var selectTool: LocalizedStringResource {
        LocalizedStringResource("Select tool", comment: "Accessibility label: the Edit toolbar's arrow tool")
    }

    static var drawTool: LocalizedStringResource {
        LocalizedStringResource("Draw tool", comment: "Accessibility label: the Edit toolbar's pencil tool")
    }

    static var eraseTool: LocalizedStringResource {
        LocalizedStringResource("Erase tool", comment: "Accessibility label: the Edit toolbar's eraser tool")
    }

    static var snapToGrid: LocalizedStringResource {
        LocalizedStringResource("Snap to grid", comment: "Accessibility label: the Edit toolbar's magnet button")
    }

    static var gridDivision: LocalizedStringResource {
        LocalizedStringResource("Grid division", comment: "Accessibility label: the Edit toolbar's division button, e.g. 1/16")
    }

    static var swing: LocalizedStringResource {
        LocalizedStringResource("Swing", comment: "Accessibility label: the Edit toolbar's swing percentage field")
    }

    static var undo: LocalizedStringResource {
        LocalizedStringResource("Undo", comment: "Accessibility label: the Edit toolbar's undo button")
    }

    static var redo: LocalizedStringResource {
        LocalizedStringResource("Redo", comment: "Accessibility label: the Edit toolbar's redo button")
    }

    static var tempo: LocalizedStringResource {
        LocalizedStringResource("Tempo", comment: "Accessibility label: a tempo field, in quarter notes a minute")
    }

    static var beatsInBar: LocalizedStringResource {
        LocalizedStringResource("Beats in a bar", comment: "Accessibility label: the time signature's numerator button")
    }

    static var beatUnit: LocalizedStringResource {
        LocalizedStringResource("Beat unit", comment: "Accessibility label: the time signature's denominator button")
    }

    static var beatOneAt: LocalizedStringResource {
        LocalizedStringResource("Beat 1 at", comment: "Accessibility label: the toolbar field for where bar 1 starts, in seconds")
    }

    static var setBeatOneFromPlayhead: LocalizedStringResource {
        LocalizedStringResource("Set beat 1 from playhead", comment: "Accessibility label: the toolbar's target button beside BEAT 1 AT")
    }

    static var keyTonic: LocalizedStringResource {
        LocalizedStringResource("Key", comment: "Accessibility label: the toolbar's key tonic button, e.g. C or none")
    }

    static var keyMode: LocalizedStringResource {
        LocalizedStringResource("Mode", comment: "Accessibility label: the toolbar's major / minor button")
    }

    // MARK: - Sidebar

    static var addInstrument: LocalizedStringResource {
        LocalizedStringResource("Add instrument", comment: "Accessibility label: the sidebar's + button")
    }

    static func instrumentCount(_ count: Int) -> LocalizedStringResource {
        LocalizedStringResource("\(count) instruments", comment: "Accessibility label: the sidebar header's instrument count")
    }

    static var instrumentCommands: LocalizedStringResource {
        LocalizedStringResource("Instrument commands", comment: "Accessibility label: the button VoiceOver offers in place of a right-click on an instrument strip")
    }

    static var mute: LocalizedStringResource {
        LocalizedStringResource("Mute", comment: "Accessibility label: an instrument strip's M button")
    }

    static var solo: LocalizedStringResource {
        LocalizedStringResource("Solo", comment: "Accessibility label: an instrument strip's S button")
    }

    static var level: LocalizedStringResource {
        LocalizedStringResource("Level", comment: "Accessibility label: an instrument strip's fader")
    }

    static var panLabel: LocalizedStringResource {
        LocalizedStringResource("Pan", comment: "Accessibility label: an instrument strip's pan slider")
    }

    /// Centre, or how far left or right, out of 100.
    static func pan(_ pan: Double) -> LocalizedStringResource {
        let amount = Int((abs(pan) * 100).rounded())

        if amount == 0 {
            return LocalizedStringResource("Center", comment: "Accessibility value: a pan slider in the middle")
        }

        return pan < 0
            ? LocalizedStringResource("Left \(amount)", comment: "Accessibility value: a pan slider to the left, out of 100")
            : LocalizedStringResource("Right \(amount)", comment: "Accessibility value: a pan slider to the right, out of 100")
    }

    static var outputLevel: LocalizedStringResource {
        LocalizedStringResource("Output level", comment: "Accessibility label: the master panel's volume slider")
    }

    static var muteInput: LocalizedStringResource {
        LocalizedStringResource("Mute input", comment: "Accessibility label: the master panel's MUTE button")
    }

    static var click: LocalizedStringResource {
        LocalizedStringResource("Click", comment: "Accessibility label: the master panel's metronome button")
    }

    static var clickLevel: LocalizedStringResource {
        LocalizedStringResource("Click level", comment: "Accessibility label: the metronome's volume slider")
    }

    static var stereoSplit: LocalizedStringResource {
        LocalizedStringResource("Stereo split", comment: "Accessibility label: the master panel's headphones button")
    }

    static var mix: LocalizedStringResource {
        LocalizedStringResource("Mix", comment: "Accessibility label: the slider between the source audio (ORIG) and the MIDI")
    }

    static func mixValue(_ mix: Double) -> LocalizedStringResource {
        let midi = Int((mix * 100).rounded())

        return LocalizedStringResource("\(midi) percent MIDI", comment: "Accessibility value: how much of the mix is the MIDI rather than the source audio")
    }

    static var soloing: LocalizedStringResource {
        LocalizedStringResource("Only this side", comment: "Accessibility value: ORIG or MIDI held, so only that side plays")
    }

    static var notSoloing: LocalizedStringResource {
        LocalizedStringResource("Both sides", comment: "Accessibility value: ORIG or MIDI not held")
    }

    static var verticalZoom: LocalizedStringResource {
        LocalizedStringResource("Piano roll vertical zoom", comment: "Accessibility label: the status bar's zoom slider")
    }

    // MARK: - Selection fields and cards

    static var instrument: LocalizedStringResource {
        LocalizedStringResource("Instrument", comment: "Accessibility label: the selection's instrument button")
    }

    static var noteStart: LocalizedStringResource {
        LocalizedStringResource("Start", comment: "Accessibility label: the selection's start field, in seconds")
    }

    static var noteLength: LocalizedStringResource {
        LocalizedStringResource("Length", comment: "Accessibility label: the selection's length field, in seconds")
    }

    static var pitch: LocalizedStringResource {
        LocalizedStringResource("Pitch", comment: "Accessibility label: the selection's pitch field, e.g. C4")
    }

    static var velocity: LocalizedStringResource {
        LocalizedStringResource("Velocity", comment: "Accessibility label: the selection's velocity slider and field")
    }

    static var lyric: LocalizedStringResource {
        LocalizedStringResource("Lyric", comment: "Accessibility label: the syllable field for a note")
    }

    static var confidence: LocalizedStringResource {
        LocalizedStringResource("Confidence", comment: "Accessibility label: how sure the model was of the selected notes")
    }

    static var pitchCurve: LocalizedStringResource {
        LocalizedStringResource("Pitch curve", comment: "Accessibility label: the selected notes' largest pitch deviation, in cents")
    }

    static var changeTo: LocalizedStringResource {
        LocalizedStringResource("Change to", comment: "Accessibility label: the strip card's instrument to move every note to")
    }

    static var splitAt: LocalizedStringResource {
        LocalizedStringResource("Split at", comment: "Accessibility label: the strip card's split pitch field")
    }

    static var sendTo: LocalizedStringResource {
        LocalizedStringResource("Send to", comment: "Accessibility label: the strip card's instrument the split notes go to")
    }

    static var markerName: LocalizedStringResource {
        LocalizedStringResource("Marker name", comment: "Accessibility label: the ruler card's marker name field")
    }

    static var chordRoot: LocalizedStringResource {
        LocalizedStringResource("Root", comment: "Accessibility label: the chord card's root button")
    }

    static var chordQuality: LocalizedStringResource {
        LocalizedStringResource("Quality", comment: "Accessibility label: the chord card's quality button, e.g. major")
    }

    static var chordBass: LocalizedStringResource {
        LocalizedStringResource("Bass", comment: "Accessibility label: the chord card's slash bass button")
    }

    // MARK: - Score cards

    static var clef: LocalizedStringResource {
        LocalizedStringResource("Clef", comment: "Accessibility label: the part card's clef button")
    }

    static var transposition: LocalizedStringResource {
        LocalizedStringResource("Transposition", comment: "Accessibility label: the part card's transposition preset button")
    }

    static var transpositionSemitones: LocalizedStringResource {
        LocalizedStringResource("Transposition in semitones", comment: "Accessibility label: the part card's transposition field")
    }

    static var tab: LocalizedStringResource {
        LocalizedStringResource("Tab", comment: "Accessibility label: the part card's tablature instrument button")
    }

    static var tuning: LocalizedStringResource {
        LocalizedStringResource("Tuning", comment: "Accessibility label: the part card's tuning preset button")
    }

    static func stringTuning(_ string: Int) -> LocalizedStringResource {
        LocalizedStringResource("String \(string) tuning", comment: "Accessibility label: one string's pitch field on the part card, numbered from the top tab line")
    }

    static var frets: LocalizedStringResource {
        LocalizedStringResource("Frets", comment: "Accessibility label: the part card's fret count field")
    }

    static var hidden: LocalizedStringResource {
        LocalizedStringResource("Hidden", comment: "Accessibility label: the part card's hide switch")
    }

    // MARK: - Settings and welcome

    static var modelSelected: LocalizedStringResource {
        LocalizedStringResource("Selected", comment: "Accessibility label: a model row's radio, the model in use")
    }

    static var modelInstalled: LocalizedStringResource {
        LocalizedStringResource("Installed", comment: "Accessibility label: a model row's radio, installed but not in use")
    }

    static var modelNotInstalled: LocalizedStringResource {
        LocalizedStringResource("Not installed", comment: "Accessibility label: a model row's radio, not downloaded")
    }

    static var downloadProgress: LocalizedStringResource {
        LocalizedStringResource("Download progress", comment: "Accessibility label: a model download's progress bar")
    }

    static var stopDownload: LocalizedStringResource {
        LocalizedStringResource("Stop download", comment: "Accessibility label: a model download's stop button")
    }

    static var projectMissing: LocalizedStringResource {
        LocalizedStringResource("Missing", comment: "Accessibility value: a recent project whose file is no longer where it was")
    }
}
