import Foundation
import NeuralSheetCore

/// The tempo map by hand (tempo map design §4): the toolbar's TEMPO, TIME and Tap act on the
/// segment under the playhead, the ruler's card on the segment under the pointer. Like the BPM,
/// the offset and the key, the map is project state, not a note edit: nothing here goes on the
/// undo stack.
extension AppModel {
    /// The bar under the playhead.
    var playheadBar: Int { editor.grid.bar(atSeconds: playheadSeconds) }

    /// The segment the toolbar shows and sets.
    var playheadSegment: GridSegment { editor.grid.segment(atBar: playheadBar) }

    func setTempo(_ bpm: Double, atBar bar: Int) {
        guard bpm.isFinite else { return }

        editor.grid.setTempo(bpm, atBar: bar)
    }

    /// The toolbar's TIME: the meter of the segment under the playhead.
    func setTimeSignature(_ meter: TimeSignature) {
        setTimeSignature(meter, atBar: playheadBar)
    }

    func setTimeSignature(_ meter: TimeSignature, atBar bar: Int) {
        editor.grid.setTimeSignature(meter, atBar: bar)
    }

    /// A segment at `bar` starting at the tempo and meter it already has there.
    func addTempoChange(atBar bar: Int) {
        editor.grid.addChange(atBar: bar)
    }

    /// The segment at `bar` folds into the one before; never bar 1's.
    func removeTempoChange(atBar bar: Int) {
        editor.grid.removeChange(atBar: bar)
    }
}
