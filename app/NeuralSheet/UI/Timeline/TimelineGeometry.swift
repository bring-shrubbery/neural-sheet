import CoreGraphics
import Foundation
import NeuralSheetCore

/// The authored extents of the timeline (`nn::metrics`), in 1.0× pixels. Multiply by the UI scale.
enum TimelineMetrics {
    static let gutterWidth: CGFloat = 46
    static let waveformHeight: CGFloat = 126
    static let rulerHeight: CGFloat = 22
    static let pianoRollY: CGFloat = waveformHeight + rulerHeight

    static let barWidth: CGFloat = 3
    static let barPitch: CGFloat = 4

    /// Centre of the 1 px line drawn at `waveformHeight / 2`, so amplitude 0 lands mid-pixel.
    static let waveformCentreY: CGFloat = waveformHeight * 0.5 + 0.5
    /// Where amplitude ±1.0 lands, measured from `waveformCentreY`.
    static let waveformAmpHalfSpan: CGFloat = 51

    /// The horizontal scrollbar's thickness (`LookAndFeel_V4::getDefaultScrollbarWidth`).
    static let scrollerThickness: CGFloat = 8

    /// The peaks are over the model's 16 kHz mono copy.
    static let peakSampleRate: Double = 16000

    static let whiteKeysPerOctave = 7
    static let semitonesPerOctave = 12
}

/// One shared description of where everything on the timeline is, read by every timeline view.
///
/// Two axes. Time runs in real (scaled) points from the left edge of the scrolled content, at
/// `100 × zoom × scale` points per second. Pitch is the JUCE `KeyboardComponentBase` layout ported
/// key for key — the roll's lanes are measured off the same numbers the key column is drawn with,
/// so the two can never disagree — kept in authored pixels and multiplied by `scale` on the way
/// out.
///
/// Main-thread only; the container owns it and the views only read it.
final class TimelineGeometry {
    // MARK: - Time axis

    var scale: CGFloat = 1
    var zoom: Double = 1
    var duration: Double = 0

    /// The clip view's width, in real points.
    var viewportWidth: CGFloat = 0

    /// Real points per second.
    var pixelsPerSecond: CGFloat { CGFloat(ZoomMath.basePixelsPerSecond * zoom) * scale }

    /// The scrolled content's width in real points: whole authored pixels, never narrower than the
    /// viewport (`CombinedAudioMidiRegion::resizeAccordingToNumSamplesAvailable`).
    var contentWidth: CGFloat {
        CGFloat(ZoomMath.contentWidth(zoom: zoom, duration: duration, viewportWidth: Double(viewportWidth / scale)))
            * scale
    }

    func x(forSeconds seconds: Double) -> CGFloat {
        CGFloat(seconds) * pixelsPerSecond
    }

    func seconds(forX x: CGFloat) -> Double {
        pixelsPerSecond > 0 ? Double(x / pixelsPerSecond) : 0
    }

    /// The playhead's x, in real points: `Playhead::computePlayheadPositionPixel` rounded to a whole
    /// authored pixel, as the C++ draws it.
    func playheadX(seconds: Double) -> CGFloat {
        guard duration > 0 else { return 0 }

        let widthAuthored = Double(contentWidth / scale)
        let span = min(ZoomMath.basePixelsPerSecond * zoom * duration, widthAuthored)
        let position = seconds / duration * span

        return CGFloat(min(max(position, 0), widthAuthored).rounded()) * scale
    }

    // MARK: - Pitch axis

    /// The octaves on show, whole octaves throughout.
    var pitchRange: PitchRange = .empty

    /// One semitone's lane height in authored pixels (`nn::zoom::rowHeight`).
    var rowHeight: CGFloat = ZoomMath.rowHeightMin

    /// The key column's height in authored pixels, which the pitch axis is laid out against.
    var keyboardHeight: CGFloat = 0

    /// `KeyboardComponentBase::firstKey`: the lowest key on screen, fractional so a wheel gesture
    /// accumulates, snapped to a whole key when laid out.
    var firstKey: Double = Double(PitchRange.empty.low)

    /// One white key's height in authored pixels (`nn::zoom::keyHeightForRowHeight`).
    var keyWidth: CGFloat {
        rowHeight * CGFloat(TimelineMetrics.semitonesPerOctave) / CGFloat(TimelineMetrics.whiteKeysPerOctave)
    }

    /// `KeyboardComponentBase::getBlackNoteLength()`, along the key: 0.65 of the column's width.
    var blackNoteLength: CGFloat { TimelineMetrics.gutterWidth * 0.65 }

    /// `getBlackNoteWidth()`: across the key, 0.58 of a white key.
    var blackNoteWidth: CGFloat { keyWidth * 0.58 }

    /// `getKeyPos(note)`: where a key starts and ends along the axis, measured upward from the
    /// bottom of the column. The key `firstKey` snaps to sits at 0 (`xOffset` in JUCE).
    func keyPosition(_ note: Int) -> (start: CGFloat, end: CGFloat) {
        let position = KeyboardLayout.keyPosition(note, keyWidth: keyWidth)
        let base = KeyboardLayout.keyPosition(Int(firstKey), keyWidth: keyWidth).start

        return (position.start - base, position.end - base)
    }

    /// `getRectangleForKey(note)`, in real points, y down, over a column `gutterWidth` wide.
    func keyRect(_ note: Int) -> CGRect {
        let position = keyPosition(note)
        let length = position.end - position.start
        let top = keyboardHeight - position.start - length
        let width = KeyboardLayout.isBlack(note) ? blackNoteLength : TimelineMetrics.gutterWidth

        return CGRect(x: 0, y: top * scale, width: width * scale, height: length * scale)
    }

    /// The top of a note's lane, in real points.
    func y(forPitch pitch: Int) -> CGFloat {
        lane(forPitch: pitch).y
    }

    /// `PianoRoll::_getNoteHeightAndWidthPianoRoll`: the lane a note draws in, in real points.
    ///
    /// White lanes run from the black key above to the black key below, so the lanes tile the
    /// column with no gaps; the two ends of the range have one neighbour only.
    func lane(forPitch pitch: Int) -> (y: CGFloat, height: CGFloat) {
        let low = pitchRange.low
        let high = pitchRange.high
        let y: CGFloat
        let height: CGFloat

        if pitch == low {
            y = noteBottomY(pitch + 1)
            height = noteBottomY(pitch) - y
        } else if pitch == high {
            y = noteTopY(pitch)
            height = noteTopY(pitch - 1) - y
        } else if KeyboardLayout.isBlack(pitch) {
            y = noteTopY(pitch)
            height = blackNoteWidth
        } else {
            y = noteBottomY(pitch + 1)
            height = noteTopY(pitch - 1) - y
        }

        return (y * scale, height * scale)
    }

    private func noteBottomY(_ note: Int) -> CGFloat {
        keyboardHeight - keyPosition(note).start
    }

    private func noteTopY(_ note: Int) -> CGFloat {
        noteBottomY(note) - (KeyboardLayout.isBlack(note) ? blackNoteWidth : keyWidth)
    }

    // MARK: - Keyboard scrolling

    /// `KeyboardComponentBase::resized`'s clamp: the whole range fits, or the top key can end at
    /// most a key's worth below the top of the column.
    func settleFirstKey() {
        let low = pitchRange.low
        let high = pitchRange.high

        firstKey = min(max(firstKey, Double(low)), Double(high))

        guard keyboardHeight > 0, keyWidth > 0 else { return }

        let start = KeyboardLayout.keyPosition(low, keyWidth: keyWidth).start
        let end = KeyboardLayout.keyPosition(high, keyWidth: keyWidth).end

        if end - start <= keyboardHeight {
            firstKey = Double(low)
            return
        }

        // The key under the point one column's height below the end of the last key, plus one.
        let probe = end - keyboardHeight

        if let note = KeyboardLayout.note(atPosition: probe, range: pitchRange, keyWidth: keyWidth) {
            let lastStartKey = note + 1

            if Int(firstKey) > lastStartKey {
                firstKey = Double(min(max(lastStartKey, low), high))
            }
        } else if probe < start {
            firstKey = Double(low)
        }
    }

    /// `Keyboard::_visibleSemitones`.
    var visibleSemitones: Int {
        guard keyWidth > 0 else { return ZoomMath.minVisibleSemitones }

        return Int((keyboardHeight / keyWidth * CGFloat(TimelineMetrics.semitonesPerOctave)
            / CGFloat(TimelineMetrics.whiteKeysPerOctave)).rounded())
    }

    /// `Keyboard::setWhiteKeyHeight`: a zoom holds the middle of the view still -- or, given
    /// `anchorY` (authored pixels from the top of the column), the pitch under that point, which
    /// is what a zoom under the pointer wants. Answers whether anything moved.
    @discardableResult
    func setRowHeight(_ newRowHeight: CGFloat, anchoringY anchorY: CGFloat? = nil) -> Bool {
        guard abs(newRowHeight - rowHeight) > 1e-6 else { return false }

        guard let anchorY, keyWidth > 0, keyboardHeight > 0 else {
            let centre = Int(firstKey) + visibleSemitones / 2
            rowHeight = newRowHeight
            firstKey = Double(centre - visibleSemitones / 2)
            settleFirstKey()

            return true
        }

        // The semitone under the anchor, fractional, measured up from the first key; after the
        // change it has to sit the same number of pixels above the bottom of the column.
        let pixelsAboveBottom = Double(keyboardHeight - anchorY)
        let anchorSemitone = firstKey + pixelsAboveBottom / Double(rowHeight)

        rowHeight = newRowHeight
        firstKey = anchorSemitone - pixelsAboveBottom / Double(rowHeight)
        settleFirstKey()

        return true
    }

    /// `KeyboardComponentBase::mouseWheelMove`, facing right: the delta in JUCE wheel units.
    func scrollKeys(byWheel delta: Double) {
        firstKey += delta * Double(keyWidth)
        settleFirstKey()
    }
}

/// `KeyboardComponentBase::getKeyPosition`, with the 0.58 black-key proportion baked in.
enum KeyboardLayout {
    static let blackNoteWidthRatio: CGFloat = 0.58

    /// Where each note of an octave starts, in white-key widths.
    private static let notePositions: [CGFloat] = {
        let ratio = blackNoteWidthRatio

        return [
            0, 1 - ratio * 0.6,
            1, 2 - ratio * 0.4,
            2,
            3, 4 - ratio * 0.7,
            4, 5 - ratio * 0.5,
            5, 6 - ratio * 0.3,
            6,
        ]
    }()

    static func isBlack(_ note: Int) -> Bool {
        switch ((note % 12) + 12) % 12 {
        case 1, 3, 6, 8, 10: true
        default: false
        }
    }

    /// The absolute position of a key along the axis, in authored pixels from MIDI 0.
    static func keyPosition(_ note: Int, keyWidth: CGFloat) -> (start: CGFloat, end: CGFloat) {
        let octave = note / 12
        let index = ((note % 12) + 12) % 12
        let start = CGFloat(octave) * 7 * keyWidth + notePositions[index] * keyWidth
        let width = isBlack(note) ? blackNoteWidthRatio * keyWidth : keyWidth

        return (start, start + width)
    }

    /// `remappedXYToNote` along the key axis with y = 0: the black key covering the position wins,
    /// then the white one. Positions are absolute, as `keyPosition` gives them.
    static func note(atPosition position: CGFloat, range: PitchRange, keyWidth: CGFloat) -> Int? {
        for note in range.low...range.high where isBlack(note) {
            let key = keyPosition(note, keyWidth: keyWidth)

            if position >= key.start && position < key.end {
                return note
            }
        }

        for note in range.low...range.high where !isBlack(note) {
            let key = keyPosition(note, keyWidth: keyWidth)

            if position >= key.start && position < key.end {
                return note
            }
        }

        return nil
    }
}
