import NeuralSheetCore
import UIKit

/// The touch timeline as VoiceOver reads it (a11y design §2, sub-issue J): the Mac's
/// `TimelineContainerView+Accessibility`, `RulerView+`, `KeyboardView`'s and `PianoRollView+`'s
/// elements over `UIAccessibilityElement`. In reading order: the ruler, an adjustable element whose
/// value is the playhead and whose swipes step it a beat; the keyboard, adjustable by the octave;
/// the chords in the lane; then the roll, a group of the notes in the band on show, in time order
/// and high to low, each read as "C4, Piano, bar 3 beat 2, half a beat" and selected as the
/// outline shows. A double tap selects a note (or seeks to it while the roll cannot be edited); the
/// actions rotor holds Select, Delete, Open Note Card and the four moves the Mac's arrow keys make.
///
/// The elements are made when VoiceOver first asks and kept until the notes or the band change,
/// never per draw; a note's element outlives a rebuild while the note does, so VoiceOver's cursor
/// stays on it through a band slide. Frames are asked of the geometry live.
extension TimelineTouchView {
    /// Called once from `init`, after the bands exist.
    func installAccessibility() {
        accessibilityLabel = String(localized: "Timeline", comment: "VoiceOver: the block holding the waveform, the ruler, the keyboard and the piano roll")
        accessibilityContainerType = .semanticGroup
        roll.accessibilityProvider = { [weak self] in self?.accessibilityNoteElements() ?? [] }
        chordLane.accessibilityProvider = { [weak self] in self?.accessibilityChordElements() ?? [] }
    }

    override var accessibilityElements: [Any]? {
        get {
            var children: [Any] = [accessibilityRuler, accessibilityKeyboard]

            if !snapshot.chords.isEmpty {
                children.append(chordLane)
            }

            children.append(roll)

            return children
        }
        set {}
    }

    /// The notes or the band changed: the next ask makes the elements again, and VoiceOver hears
    /// the layout moved, its cursor kept where it is.
    func invalidateAccessibilityElements(notesChanged: Bool) {
        if notesChanged {
            accessibilityNoteIndexIsStale = true
        }

        guard accessibilityNotes != nil || accessibilityChords != nil else { return }

        accessibilityNotes = nil
        accessibilityChords = nil

        if UIAccessibility.isVoiceOverRunning {
            UIAccessibility.post(notification: .layoutChanged,
                                 argument: UIAccessibility.focusedElement(using: .notificationVoiceOver))
        }
    }

    /// The outline moved: VoiceOver's cursor goes to the first selected note, which it reads with
    /// its new state.
    func accessibilitySelectionDidChange() {
        guard UIAccessibility.isVoiceOverRunning, let notes = accessibilityNotes else { return }

        let selection = snapshot.selection

        if let first = notes.first(where: { selection.contains($0.id) }) {
            UIAccessibility.post(notification: .layoutChanged, argument: first.element)
        }
    }

    // MARK: - The ruler

    func makeAccessibilityRuler() -> DrawnTouchElement {
        let element = DrawnTouchElement(in: self, traits: [], rect: { [weak self] in
            guard let self else { return nil }

            let k = geometry.scale

            return CGRect(x: scrollView.frame.minX, y: geometry.waveformHeight * k,
                          width: scrollView.bounds.width, height: TimelineMetrics.rulerHeight * k)
        }, label: {
            String(localized: "Ruler", comment: "VoiceOver: the time ruler above the piano roll; its value is the playhead")
        })

        element.value = { [weak self] in
            guard let self, model.canPlay else { return nil }

            let seconds = model.engine.playheadSeconds
            let time = TimeFormat.transport(seconds)
            let position = model.editor.grid.barBeat(at: seconds + 1e-6)

            return String(localized: "\(time), bar \(position.bar) beat \(position.beat)",
                          comment: "VoiceOver: the ruler's value, the playhead's time then its bar and beat")
        }
        element.increment = { [weak self] in self?.stepPlayhead(byBeats: 1) }
        element.decrement = { [weak self] in self?.stepPlayhead(byBeats: -1) }

        return element
    }

    /// To the next or the previous beat line of the meter, the one the ruler draws, so a step lands
    /// on a beat whatever the playhead was between; clamped to the take. The Mac's ruler's step.
    private func stepPlayhead(byBeats beats: Int) {
        guard model.canPlay else { return }

        let grid = model.editor.grid
        let seconds = model.engine.playheadSeconds
        let segment = grid.segment(atSeconds: seconds)
        let beat = segment.timeSignature.beatLength * 60 / segment.bpm
        let epsilon = 1e-6
        let target: Double?

        if beats > 0 {
            target = grid.beatLines(from: seconds + epsilon, to: seconds + 2 * beat)
                .first { $0.seconds > seconds + epsilon }?.seconds
        } else {
            target = grid.beatLines(from: max(0, seconds - 2 * beat), to: seconds)
                .last { $0.seconds < seconds - epsilon }?.seconds
        }

        let next = min(max(0, target ?? seconds + Double(beats) * beat), geometry.duration)

        model.seek(toSeconds: next)
        updatePlayhead()
        wakeDisplayLink()
        scrollToShow(seconds: next)
    }

    // MARK: - The keyboard

    func makeAccessibilityKeyboard() -> DrawnTouchElement {
        let element = DrawnTouchElement(in: self, traits: [], rect: { [weak self] in self?.keyboard.frame }, label: {
            String(localized: "Keyboard", comment: "VoiceOver: the piano keys left of the piano roll")
        })

        element.value = { [weak self] in
            guard let self else { return nil }

            let geometry = geometry
            let range = geometry.pitchRange
            let height = keyboard.bounds.height
            let shown = range.low <= range.high
                ? (range.low...range.high).filter { pitch in
                    let rect = geometry.keyRect(pitch)
                    return rect.maxY > 0 && rect.minY < height
                }
                : []

            guard let low = shown.first, let high = shown.last else { return nil }

            return String(localized: "\(TimeFormat.pitchName(low)) to \(TimeFormat.pitchName(high))",
                          comment: "VoiceOver: the keys on show, lowest to highest, e.g. \"C2 to C6\"")
        }
        element.increment = { [weak self] in self?.scrollPitch(bySemitones: 12) }
        element.decrement = { [weak self] in self?.scrollPitch(bySemitones: -12) }

        return element
    }

    /// The lanes and the keys up (positive) or down by whole semitones, as the Mac's keyboard
    /// scrolls for VoiceOver.
    func scrollPitch(bySemitones semitones: Int) {
        geometry.firstKey += Double(semitones)
        geometry.settleFirstKey()
        layoutBands()
        roll.setNeedsDisplay()
        keyboard.setNeedsDisplay()
    }

    // MARK: - Chords

    private func accessibilityChordElements() -> [Any] {
        if let accessibilityChords { return accessibilityChords }

        let chords = chordLane.chords
        let labels = chordLane.labels
        let start = geometry.seconds(forX: bandWindow.minX)
        let end = geometry.seconds(forX: bandWindow.maxX)
        let grid = model.editor.grid

        let elements = chords.indices
            .filter { $0 < labels.count && chords[$0].seconds >= start && chords[$0].seconds <= end }
            .map { index -> DrawnTouchElement in
                let event = chords[index]
                let position = grid.barBeat(at: event.seconds + 1e-6)
                let symbol = labels[index]
                let label = String(localized: "\(symbol), bar \(position.bar) beat \(position.beat)",
                                   comment: "VoiceOver: a chord symbol in the chord lane, e.g. \"Am7, bar 3 beat 1\"")
                let element = DrawnTouchElement(in: chordLane, traits: .staticText, rect: { [weak self] in
                    guard let self else { return nil }

                    let x = geometry.x(forSeconds: event.seconds)
                    let next = index + 1 < chords.count ? geometry.x(forSeconds: chords[index + 1].seconds) : chordLane.bounds.maxX

                    return CGRect(x: x, y: 0, width: max(geometry.scale, next - x), height: chordLane.bounds.height)
                }, label: { label })

                element.didBecomeFocused = { [weak self] in self?.scrollToShow(seconds: event.seconds) }

                return element
            }

        accessibilityChords = elements

        return elements
    }

    // MARK: - Notes

    private func accessibilityNoteElements() -> [Any] {
        if let accessibilityNotes { return accessibilityNotes.map(\.element) }

        let painter = roll.painter
        let previous = Dictionary(accessibilityNotesKept.map { ($0.id, $0.element) }, uniquingKeysWith: { first, _ in first })

        refreshNoteIndexIfStale()

        let made = bandNoteIndices().map { offset -> (id: NoteID, element: DrawnTouchElement) in
            let id = painter.ids[offset]

            return (id, previous[id] ?? noteElement(id))
        }

        accessibilityNotes = made
        accessibilityNotesKept = made

        return made.map(\.element)
    }

    /// Every note whose seconds cross the band, once each, left to right and high to low.
    private func bandNoteIndices() -> [Int] {
        let painter = roll.painter

        guard !painter.buckets.isEmpty, model.canPlay, !model.notesArePlaceholders else { return [] }

        let first = max(0, Int(geometry.seconds(forX: bandWindow.minX)))
        let last = min(painter.buckets.count - 1, Int(geometry.seconds(forX: bandWindow.maxX)))

        guard first <= last else { return [] }

        var seen = Set<Int>()
        var indices: [Int] = []

        for bucket in first...last {
            for index in painter.buckets[bucket] where seen.insert(index).inserted {
                indices.append(index)
            }
        }

        let notes = painter.notes

        return indices.sorted { a, b in
            notes[a].startTime != notes[b].startTime ? notes[a].startTime < notes[b].startTime : notes[a].pitch > notes[b].pitch
        }
    }

    /// The note `id` names as the roll draws it now, nil once it is gone.
    private func accessibilityNote(_ id: NoteID) -> NoteEvent? {
        refreshNoteIndexIfStale()

        guard let index = accessibilityNoteIndex[id], index < roll.painter.notes.count, roll.painter.ids[index] == id else { return nil }

        return roll.painter.notes[index]
    }

    /// Each note's place in the roll's arrays, made again after the notes changed.
    private func refreshNoteIndexIfStale() {
        guard accessibilityNoteIndexIsStale else { return }

        var index: [NoteID: Int] = [:]

        for (offset, id) in roll.painter.ids.enumerated() {
            index[id] = offset
        }

        accessibilityNoteIndex = index
        accessibilityNoteIndexIsStale = false
    }

    private func noteElement(_ id: NoteID) -> DrawnTouchElement {
        let element = DrawnTouchElement(in: roll, traits: .button, rect: { [weak self] in
            guard let self, let note = accessibilityNote(id) else { return nil }

            return roll.painter.noteRect(note, height: roll.bounds.height)
        }, label: { [weak self] in
            guard let self, let note = accessibilityNote(id) else { return "" }

            return NoteSpeech.description(of: note, grid: model.editor.grid)
        })

        element.isSelected = { [weak self] in self?.snapshot.selection.contains(id) ?? false }

        element.press = { [weak self] in
            guard let self, let note = accessibilityNote(id) else { return false }

            if model.canEdit {
                model.setSelection([id])
                model.audition(note)
            } else {
                model.seek(toSeconds: note.startTime)
                updatePlayhead()
                wakeDisplayLink()
            }

            return true
        }

        element.actions = { [weak self] in
            guard let self, model.canEdit else { return [] }

            return noteActions(id)
        }

        element.didBecomeFocused = { [weak self] in
            guard let self, let note = accessibilityNote(id) else { return }

            scrollToShow(seconds: note.startTime, pitch: note.pitch)
        }

        return element
    }

    /// Through the same model commands a touch uses: a note acted on is selected first.
    private func noteActions(_ id: NoteID) -> [UIAccessibilityCustomAction] {
        let model = model

        func selectingFirst(_ perform: @escaping () -> Void) -> () -> Void {
            {
                if !model.editor.selection.contains(id) {
                    model.setSelection([id])
                }

                perform()
            }
        }

        return [
            UIAccessibilityCustomAction(String(localized: "Select", comment: "VoiceOver action on a note: select it")) {
                model.setSelection([id])
                model.auditionSelection()
            },
            UIAccessibilityCustomAction(String(localized: "Delete", comment: "VoiceOver action on a note: delete it")) {
                model.setSelection([id])
                model.deleteSelection()
            },
            UIAccessibilityCustomAction(String(localized: "Open Note Card", comment: "VoiceOver action on a note: open the card with its fields")) { [weak self] in
                guard let self, let note = accessibilityNote(id) else { return }

                model.setSelection([id])
                openNoteCard(for: note)
            },
            UIAccessibilityCustomAction(String(localized: "Move Left", comment: "VoiceOver action on a note: a grid step earlier"),
                                        perform: selectingFirst { model.nudgeSelection(steps: -1, semitones: 0) }),
            UIAccessibilityCustomAction(String(localized: "Move Right", comment: "VoiceOver action on a note: a grid step later"),
                                        perform: selectingFirst { model.nudgeSelection(steps: 1, semitones: 0) }),
            UIAccessibilityCustomAction(String(localized: "Move Up", comment: "VoiceOver action on a note: a semitone higher"),
                                        perform: selectingFirst { model.nudgeSelection(steps: 0, semitones: 1) }),
            UIAccessibilityCustomAction(String(localized: "Move Down", comment: "VoiceOver action on a note: a semitone lower"),
                                        perform: selectingFirst { model.nudgeSelection(steps: 0, semitones: -1) }),
        ]
    }

    // MARK: - Scrolling to the cursor

    /// VoiceOver's cursor went to something off screen: the view scrolls to it, a third of the
    /// way in, and pans the lanes to its pitch.
    func scrollToShow(seconds: Double, pitch: Int? = nil) {
        let x = geometry.x(forSeconds: seconds)
        let viewport = scrollView.bounds.width
        let offset = scrollView.contentOffset.x

        if x < offset || x > offset + viewport * 0.9 {
            let maxX = max(0, scrollView.contentSize.width - viewport)
            isSettingOffset = true
            scrollView.contentOffset.x = min(max(0, x - viewport / 3), maxX)
            isSettingOffset = false
            layoutBands()
        }

        if let pitch {
            let lane = geometry.lane(forPitch: pitch)
            let height = keyboard.bounds.height

            if lane.y < 0 || lane.y + lane.height > height {
                let rows = Double(geometry.visibleSemitones)
                geometry.firstKey = Double(pitch) - rows / 2
                geometry.settleFirstKey()
                layoutBands()
                roll.setNeedsDisplay()
                keyboard.setNeedsDisplay()
            }
        }

        updatePlayhead()
        wakeDisplayLink()
    }
}
