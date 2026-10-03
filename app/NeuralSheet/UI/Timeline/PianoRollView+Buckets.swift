import AppKit
import NeuralSheetCore

/// The second buckets a repaint finds its notes by, shared by the notes and the compared
/// version's ghosts (versions design §2); out of `PianoRollView.swift` to keep that file focused.
extension PianoRollView {
    /// `result[s]` holds the indices of every note of `notes` drawn over second `s`, in note
    /// order: the notes' and the ghosts' buckets alike.
    static func secondBuckets(_ notes: [NoteEvent]) -> [[Int]] {
        let seconds = Int((notes.map { PianoRollView.drawnEnd(of: $0) }.max() ?? 0).rounded(.up)) + 1
        var newBuckets = [[Int]](repeating: [], count: max(1, seconds))

        for (index, note) in notes.enumerated() {
            let first = max(0, Int(note.startTime))
            let last = max(first, Int(PianoRollView.drawnEnd(of: note)))

            for bucket in first...min(last, newBuckets.count - 1) {
                newBuckets[bucket].append(index)
            }
        }

        return newBuckets
    }

    /// The same for any notes and their ``secondBuckets(_:)``: the ghosts' too.
    func indices(crossing dirtyRect: CGRect, of notes: [NoteEvent], buckets: [[Int]]) -> [Int] {
        guard !notes.isEmpty, !buckets.isEmpty else { return [] }

        let fromSeconds = max(0, geometry.seconds(forX: dirtyRect.minX))
        let toSeconds = geometry.seconds(forX: dirtyRect.maxX)
        let firstBucket = min(Int(fromSeconds), buckets.count - 1)
        let lastBucket = min(Int(toSeconds), buckets.count - 1)

        guard firstBucket <= lastBucket else { return [] }

        // Gathered and sorted rather than drawn bucket by bucket, so overlapping notes stack in the
        // order the transcription lists them, wherever their buckets start.
        var indices: [Int] = []

        for bucket in firstBucket...lastBucket {
            for index in buckets[bucket] {
                let note = notes[index]
                let startBucket = max(0, Int(note.startTime))

                if bucket == max(startBucket, firstBucket) {
                    indices.append(index)
                }
            }
        }

        indices.sort()

        return indices
    }
}
