import AppKit
import NeuralSheetCore

/// Where everything in a ``ScoreDocument`` goes on the page (score design §2): systems of
/// measures wrapping to a width, the staff rows inside each system, the x of every onset in a
/// measure so all staves line up, and the inverse for the cursor and the click.
///
/// All lengths in points, already scaled; `sp` is the staff space.
struct ScoreLayout {
    /// One staff of one part, at its y in a system.
    struct StaffRow {
        var partIndex: Int
        var staffIndex: Int
        /// The bottom line's y within the score view.
        var bottomLineY: CGFloat
        var clef: Clef
    }

    /// One measure's place in a system.
    struct MeasureBox {
        /// 0-based index into the document's measures.
        var index: Int
        var x: CGFloat
        var width: CGFloat
        /// Where the music starts, past the clef and signatures of a system's first measure.
        var contentX: CGFloat
        /// Every onset in the measure (units from its start, across all staves) and its x. Sorted
        /// by units; always begins at 0 and ends with the measure's end at `barUnits`.
        var onsets: [(units: Int, x: CGFloat)]

        var endX: CGFloat { x + width }

        /// The x for a fractional position, between the onsets around it.
        func x(forUnits units: Double) -> CGFloat {
            guard let first = onsets.first, let last = onsets.last else { return contentX }
            guard units > Double(first.units) else { return first.x }
            guard units < Double(last.units) else { return last.x }

            for index in 1..<onsets.count where Double(onsets[index].units) >= units {
                let a = onsets[index - 1]
                let b = onsets[index]
                let t = (units - Double(a.units)) / Double(max(1, b.units - a.units))

                return a.x + (b.x - a.x) * CGFloat(t)
            }

            return last.x
        }

        /// The inverse of ``x(forUnits:)``.
        func units(forX x: CGFloat) -> Double {
            guard let first = onsets.first, let last = onsets.last else { return 0 }
            guard x > first.x else { return Double(first.units) }
            guard x < last.x else { return Double(last.units) }

            for index in 1..<onsets.count where onsets[index].x >= x {
                let a = onsets[index - 1]
                let b = onsets[index]
                let t = (x - a.x) / max(1, b.x - a.x)

                return Double(a.units) + Double(b.units - a.units) * Double(t)
            }

            return Double(last.units)
        }
    }

    struct System {
        var frame: CGRect
        var rows: [StaffRow]
        var measures: [MeasureBox]
        /// Whether this system's first measure carries the time signature (the first of all).
        var showsTimeSignature: Bool

        /// The staves' vertical extent: the top staff's top line to the bottom staff's bottom line.
        var staffTop: CGFloat { (rows.first?.bottomLineY ?? frame.minY) - 4 * spaceHint }
        var staffBottom: CGFloat { rows.last?.bottomLineY ?? frame.maxY }
        var spaceHint: CGFloat = 8
    }

    let sp: CGFloat
    let width: CGFloat
    var systems: [System] = []
    var totalHeight: CGFloat = 0

    // MARK: - Metrics, in staff spaces

    static let leftMargin: CGFloat = 9
    static let rightMargin: CGFloat = 2
    static let topMargin: CGFloat = 7
    static let bottomMargin: CGFloat = 4
    static let staffGap: CGFloat = 6
    static let partGap: CGFloat = 9
    static let systemGap: CGFloat = 8
    static let clefWidth: CGFloat = 3.6
    static let accidentalWidth: CGFloat = 1.0
    static let timeSignatureWidth: CGFloat = 2.8
    static let measurePadLeft: CGFloat = 1.6
    static let measurePadRight: CGFloat = 0.6
    static let minimumMeasureWidth: CGFloat = 6

    init(document: ScoreDocument, width: CGFloat, sp: CGFloat) {
        self.sp = sp
        self.width = width

        guard document.measureCount > 0, !document.parts.isEmpty else {
            totalHeight = ScoreLayout.topMargin * sp
            return
        }

        let available = max(sp * 12, width - (ScoreLayout.leftMargin + ScoreLayout.rightMargin) * sp)
        let naturalWidths = (0..<document.measureCount).map { naturalWidth(measure: $0, in: document) }
        let signatureWidth = CGFloat(abs(document.fifths)) * ScoreLayout.accidentalWidth * sp
        let prefixFirst = (ScoreLayout.clefWidth + ScoreLayout.timeSignatureWidth + 1) * sp + signatureWidth
        let prefixLater = (ScoreLayout.clefWidth + 1) * sp + signatureWidth

        // Pack measures into systems.
        var ranges: [Range<Int>] = []
        var start = 0
        while start < document.measureCount {
            let prefix = ranges.isEmpty ? prefixFirst : prefixLater
            var used = prefix
            var end = start

            while end < document.measureCount {
                let next = naturalWidths[end]
                if end > start, used + next > available { break }
                used += next
                end += 1
            }

            ranges.append(start ..< end)
            start = end
        }

        // Lay them out.
        let systemHeight = ScoreLayout.systemHeight(for: document, sp: sp)
        var y = ScoreLayout.topMargin * sp
        let x0 = ScoreLayout.leftMargin * sp

        for (systemIndex, range) in ranges.enumerated() {
            let prefix = systemIndex == 0 ? prefixFirst : prefixLater
            let natural = range.reduce(prefix) { $0 + naturalWidths[$1] }
            let isLast = systemIndex == ranges.count - 1
            // Every system but the last fills the width; the last keeps its natural spacing
            // unless it has to shrink.
            let stretch = isLast ? min(1, available / natural) : available / natural

            var measures: [MeasureBox] = []
            var x = x0

            for (position, measureIndex) in range.enumerated() {
                let measurePrefix = position == 0 ? prefix : 0
                let boxWidth = (measurePrefix + naturalWidths[measureIndex]) * stretch
                let contentX = x + measurePrefix * stretch
                let onsets = onsetXs(measure: measureIndex, in: document, contentX: contentX,
                                     contentWidth: naturalWidths[measureIndex] * stretch)

                measures.append(MeasureBox(index: measureIndex, x: x, width: boxWidth, contentX: contentX, onsets: onsets))
                x += boxWidth
            }

            var rows: [StaffRow] = []
            var rowY = y

            for (partIndex, part) in document.parts.enumerated() {
                for (staffIndex, staff) in part.staves.enumerated() {
                    rowY += 4 * sp
                    rows.append(StaffRow(partIndex: partIndex, staffIndex: staffIndex, bottomLineY: rowY, clef: staff.clef))
                    rowY += ScoreLayout.staffGap * sp
                }

                rowY += (ScoreLayout.partGap - ScoreLayout.staffGap) * sp
            }

            var system = System(frame: CGRect(x: x0, y: y, width: x - x0, height: systemHeight),
                                rows: rows, measures: measures, showsTimeSignature: systemIndex == 0)
            system.spaceHint = sp
            systems.append(system)

            y += systemHeight + ScoreLayout.systemGap * sp
        }

        totalHeight = y - ScoreLayout.systemGap * sp + ScoreLayout.bottomMargin * sp
    }

    /// The staves of every part, stacked, with the gaps between.
    static func systemHeight(for document: ScoreDocument, sp: CGFloat) -> CGFloat {
        var height: CGFloat = 0

        for part in document.parts {
            height += CGFloat(part.staves.count) * 4 * sp
            height += CGFloat(max(0, part.staves.count - 1)) * staffGap * sp
            height += partGap * sp
        }

        return max(0, height - partGap * sp)
    }

    // MARK: - Horizontal spacing

    /// Every distinct onset in the measure across all staves, with the widest accidental
    /// column at each.
    private func onsetTable(measure: Int, in document: ScoreDocument) -> [(units: Int, accidentals: Int)] {
        var accidentals: [Int: Int] = [:]

        for part in document.parts {
            for staff in part.staves where measure < staff.measures.count {
                for piece in staff.measures[measure].pieces where !piece.isWholeMeasureRest {
                    let count = piece.notes.filter { $0.accidental != nil }.count
                    accidentals[piece.startUnits] = max(accidentals[piece.startUnits] ?? 0, count)
                }
            }
        }

        if accidentals.isEmpty { accidentals[0] = 0 }

        return accidentals.keys.sorted().map { (units: $0, accidentals: accidentals[$0] ?? 0) }
    }

    /// How wide a stretch of `units` needs to be: a 32nd gets 1.6 spaces, and each doubling 0.9
    /// more, so long notes take room without dwarfing the short ones.
    private func gapWidth(units: Int) -> CGFloat {
        let ratio = max(1, Double(units) / 3)

        return sp * CGFloat(1.6 + 0.9 * log2(ratio))
    }

    private func naturalWidth(measure: Int, in document: ScoreDocument) -> CGFloat {
        let table = onsetTable(measure: measure, in: document)
        var width = ScoreLayout.measurePadLeft * sp

        for (index, entry) in table.enumerated() {
            let next = index + 1 < table.count ? table[index + 1].units : MusicXMLWriter.barUnits
            width += CGFloat(min(entry.accidentals, 2)) * ScoreLayout.accidentalWidth * sp
            width += gapWidth(units: next - entry.units)
        }

        width += ScoreLayout.measurePadRight * sp

        return max(width, ScoreLayout.minimumMeasureWidth * sp)
    }

    /// The x of each onset inside `[contentX, contentX + contentWidth)`, spaced as
    /// ``naturalWidth`` spaced them and scaled to fit.
    private func onsetXs(measure: Int, in document: ScoreDocument, contentX: CGFloat, contentWidth: CGFloat) -> [(units: Int, x: CGFloat)] {
        let table = onsetTable(measure: measure, in: document)
        var positions: [(Int, CGFloat)] = []
        var cursor = ScoreLayout.measurePadLeft * sp

        for (index, entry) in table.enumerated() {
            cursor += CGFloat(min(entry.accidentals, 2)) * ScoreLayout.accidentalWidth * sp
            positions.append((entry.units, cursor))
            let next = index + 1 < table.count ? table[index + 1].units : MusicXMLWriter.barUnits
            cursor += gapWidth(units: next - entry.units)
        }

        let natural = max(cursor + ScoreLayout.measurePadRight * sp, ScoreLayout.minimumMeasureWidth * sp)
        let scale = contentWidth / natural

        var result = positions.map { (units: $0.0, x: contentX + $0.1 * scale) }
        result.append((units: MusicXMLWriter.barUnits, x: contentX + contentWidth - ScoreLayout.measurePadRight * sp * scale))

        return result
    }

    // MARK: - Lookups

    /// The system and box holding measure `index`.
    func box(forMeasure index: Int) -> (system: System, box: MeasureBox)? {
        for system in systems {
            if let box = system.measures.first(where: { $0.index == index }) {
                return (system, box)
            }
        }

        return nil
    }

    /// The measure and the position in it under `point`, or nil off the music.
    func hitTest(_ point: CGPoint) -> (measure: Int, units: Double)? {
        for system in systems where point.y >= system.frame.minY - ScoreLayout.systemGap * sp / 2
            && point.y <= system.frame.maxY + ScoreLayout.systemGap * sp / 2
        {
            for box in system.measures where point.x >= box.x && point.x < box.endX {
                return (box.index, box.units(forX: point.x))
            }

            if let first = system.measures.first, point.x < first.x {
                return (first.index, 0)
            }

            if let last = system.measures.last, point.x >= last.endX {
                return (last.index, Double(MusicXMLWriter.barUnits))
            }
        }

        return nil
    }
}
