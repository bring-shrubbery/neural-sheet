import Foundation

/// Where everything in a ``ScoreDocument`` goes in a continuous column (score design §2,
/// arrangement design §3.5): systems of measures wrapping to a width, the staff and tab rows
/// inside each system, the x of every onset in a measure so all rows line up, and the inverse
/// for the cursor and the click. A page layout stacks these systems onto pages.
///
/// All lengths in points, already scaled; `sp` is the staff space.
public struct ScoreSystemLayout: Sendable {
    /// One row of one part — a staff or its tab — at its y in a system.
    public struct StaffRow: Equatable, Sendable {
        public enum Kind: Equatable, Sendable {
            case staff(index: Int, clef: Clef)
            case tab
        }

        public var partIndex: Int
        public var kind: Kind
        /// The bottom line's y.
        public var bottomLineY: CGFloat
        /// The lines' extent above the bottom line: 4 spaces for a staff, (strings − 1) × 1.5 for a tab.
        public var height: CGFloat

        public var topLineY: CGFloat { bottomLineY - height }
    }

    /// One measure's place in a system.
    public struct MeasureBox: Sendable {
        /// 0-based index into the document's measures.
        public var index: Int
        public var x: CGFloat
        public var width: CGFloat
        /// Where the music starts, past the clef and signatures of a system's first measure.
        public var contentX: CGFloat
        /// Every onset in the measure (units from its start, across all rows) and its x. Sorted
        /// by units; always begins at 0 and ends with the measure's end at its length.
        public var onsets: [(units: Int, x: CGFloat)]
        /// Where a meter change inside a system is drawn, before the music; nil when the measure
        /// has none, or when it opens its system and the prefix draws it.
        public var timeSignatureX: CGFloat? = nil

        public var endX: CGFloat { x + width }

        /// The x for a fractional position, between the onsets around it.
        public func x(forUnits units: Double) -> CGFloat {
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
        public func units(forX x: CGFloat) -> Double {
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

    public struct System: Sendable {
        public var frame: CGRect
        public var rows: [StaffRow]
        public var measures: [MeasureBox]
        /// Whether the prefix draws the time signature: the system's first measure shows one
        /// (the first of all, or a meter change that opens the system; tempo map design §2).
        public var showsTimeSignature: Bool
        /// The score's first system, which names the parts in full.
        public var isFirst: Bool

        /// The rows' vertical extent: the top row's top line to the bottom row's bottom line.
        public var staffTop: CGFloat { rows.first.map { $0.topLineY } ?? frame.minY }
        public var staffBottom: CGFloat { rows.last?.bottomLineY ?? frame.maxY }

        /// The same system `dy` further down: the frame and every row move, the x stays.
        public func offset(by dy: CGFloat) -> System {
            var moved = self
            moved.frame.origin.y += dy
            moved.rows = rows.map { row in
                var row = row
                row.bottomLineY += dy
                return row
            }
            return moved
        }

        /// The same system `dx` further right: the frame, every box and every onset move, the
        /// rows stay.
        public func offsetX(by dx: CGFloat) -> System {
            var moved = self
            moved.frame.origin.x += dx
            moved.measures = measures.map { box in
                var box = box
                box.x += dx
                box.contentX += dx
                box.onsets = box.onsets.map { (units: $0.units, x: $0.x + dx) }
                return box
            }
            return moved
        }
    }

    public let sp: CGFloat
    public let width: CGFloat
    public private(set) var systems: [System] = []
    public private(set) var totalHeight: CGFloat = 0

    // MARK: - Metrics, in staff spaces

    public static let leftMargin: CGFloat = 9
    public static let rightMargin: CGFloat = 2
    public static let topMargin: CGFloat = 7
    public static let bottomMargin: CGFloat = 4
    /// Between two staves of one part.
    public static let staffGap: CGFloat = 6
    /// Between a part's last staff and its tab.
    public static let tabGap: CGFloat = 5
    /// Between a tab's lines.
    public static let tabLineGap: CGFloat = 1.5
    public static let partGap: CGFloat = 9
    public static let systemGap: CGFloat = 8
    public static let clefWidth: CGFloat = 3.6
    public static let accidentalWidth: CGFloat = 1.0
    public static let timeSignatureWidth: CGFloat = 2.8
    public static let measurePadLeft: CGFloat = 1.6
    public static let measurePadRight: CGFloat = 0.6
    public static let minimumMeasureWidth: CGFloat = 6

    public init(document: ScoreDocument, arrangement: ScoreArrangement, width: CGFloat, sp: CGFloat) {
        self.sp = sp
        self.width = width

        guard document.measureCount > 0, !document.parts.isEmpty else {
            totalHeight = ScoreSystemLayout.topMargin * sp
            return
        }

        let available = max(sp * 12, width - (ScoreSystemLayout.leftMargin + ScoreSystemLayout.rightMargin) * sp)
        let naturalWidths = (0..<document.measureCount).map { naturalWidth(measure: $0, in: document) }
        // The renderer draws each part's written signature (the project key's, transposed with
        // the part), so the prefix reserves the widest of them, not the project key's own: a
        // project in C with a trumpet at +2 still needs room for two sharps.
        let widestSignature = document.parts.map { abs($0.writtenFifths) }.max() ?? 0
        let signatureWidth = CGFloat(widestSignature) * ScoreSystemLayout.accidentalWidth * sp
        let meterWidth = ScoreSystemLayout.timeSignatureWidth * sp
        // A meter shown at a measure: in the prefix when the measure opens a system, before its
        // music otherwise.
        let showsMeter = (0..<document.measureCount).map { $0 < document.bars.count && document.bars[$0].showsTimeSignature }
        let prefixBase = (ScoreSystemLayout.clefWidth + 1) * sp + signatureWidth

        func prefix(startingAt measure: Int) -> CGFloat {
            prefixBase + (showsMeter[measure] ? meterWidth : 0)
        }

        func lead(_ measure: Int, opensSystem: Bool) -> CGFloat {
            !opensSystem && showsMeter[measure] ? meterWidth : 0
        }

        // Pack measures into systems.
        var ranges: [Range<Int>] = []
        var start = 0
        while start < document.measureCount {
            var used = prefix(startingAt: start)
            var end = start

            while end < document.measureCount {
                let next = naturalWidths[end] + lead(end, opensSystem: end == start)
                if end > start, used + next > available { break }
                used += next
                end += 1
            }

            ranges.append(start ..< end)
            start = end
        }

        // Lay them out.
        let systemHeight = ScoreSystemLayout.systemHeight(for: document, arrangement: arrangement, sp: sp)
        var y = ScoreSystemLayout.topMargin * sp
        let x0 = ScoreSystemLayout.leftMargin * sp

        for (systemIndex, range) in ranges.enumerated() {
            let prefix = prefix(startingAt: range.lowerBound)
            let natural = range.reduce(prefix) { $0 + naturalWidths[$1] + lead($1, opensSystem: $1 == range.lowerBound) }
            let isLast = systemIndex == ranges.count - 1
            // Every system but the last fills the width; the last keeps its natural spacing
            // unless it has to shrink.
            let stretch = isLast ? min(1, available / natural) : available / natural

            var measures: [MeasureBox] = []
            var x = x0

            for (position, measureIndex) in range.enumerated() {
                let meterLead = lead(measureIndex, opensSystem: position == 0)
                let measurePrefix = (position == 0 ? prefix : 0) + meterLead
                let boxWidth = (measurePrefix + naturalWidths[measureIndex]) * stretch
                let contentX = x + measurePrefix * stretch
                let onsets = onsetXs(measure: measureIndex, in: document, contentX: contentX,
                                     contentWidth: naturalWidths[measureIndex] * stretch)
                var box = MeasureBox(index: measureIndex, x: x, width: boxWidth, contentX: contentX, onsets: onsets)
                box.timeSignatureX = meterLead > 0 ? x + 0.3 * sp * stretch : nil

                measures.append(box)
                x += boxWidth
            }

            let rows = ScoreSystemLayout.rows(for: document, top: y, sp: sp)

            systems.append(System(frame: CGRect(x: x0, y: y, width: x - x0, height: systemHeight),
                                  rows: rows, measures: measures, showsTimeSignature: showsMeter[range.lowerBound],
                                  isFirst: systemIndex == 0))

            y += systemHeight + ScoreSystemLayout.systemGap * sp
        }

        totalHeight = y - ScoreSystemLayout.systemGap * sp + ScoreSystemLayout.bottomMargin * sp
    }

    // MARK: - Vertical stacking

    /// Every part's staves then its tab, stacked from `top`, with the gaps between.
    static func rows(for document: ScoreDocument, top: CGFloat, sp: CGFloat) -> [StaffRow] {
        var rows: [StaffRow] = []
        var rowY = top

        for (partIndex, part) in document.parts.enumerated() {
            var rowsOfPart = 0

            for (staffIndex, staff) in part.staves.enumerated() {
                if rowsOfPart > 0 { rowY += ScoreSystemLayout.staffGap * sp }
                rowY += 4 * sp
                rows.append(StaffRow(partIndex: partIndex, kind: .staff(index: staffIndex, clef: staff.clef), bottomLineY: rowY, height: 4 * sp))
                rowsOfPart += 1
            }

            if let tab = part.tab {
                if rowsOfPart > 0 { rowY += ScoreSystemLayout.tabGap * sp }
                let height = CGFloat(max(1, tab.tuning.count - 1)) * ScoreSystemLayout.tabLineGap * sp
                rowY += height
                rows.append(StaffRow(partIndex: partIndex, kind: .tab, bottomLineY: rowY, height: height))
                rowsOfPart += 1
            }

            rowY += ScoreSystemLayout.partGap * sp
        }

        return rows
    }

    /// The rows of every part, stacked, with the gaps between: the last row's bottom line less
    /// the trailing part gap.
    public static func systemHeight(for document: ScoreDocument, arrangement: ScoreArrangement, sp: CGFloat) -> CGFloat {
        guard let last = rows(for: document, top: 0, sp: sp).last else { return 0 }

        return last.bottomLineY
    }

    // MARK: - Horizontal spacing

    /// Every distinct onset in the measure across all rows, with the widest accidental column
    /// at each. A tab's pieces share its staves' onsets; it only adds any when the part is tab
    /// alone.
    private func onsetTable(measure: Int, in document: ScoreDocument) -> [(units: Int, accidentals: Int)] {
        var accidentals: [Int: Int] = [:]

        for part in document.parts {
            for measures in part.staves.map(\.measures) + (part.tab.map { [$0.measures] } ?? []) where measure < measures.count {
                for piece in measures[measure].pieces where !piece.isWholeMeasureRest {
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

    /// The measure's length in units: its bar's, or a 4/4 bar's for a document without bars.
    private func length(of measure: Int, in document: ScoreDocument) -> Int {
        measure < document.bars.count ? document.bars[measure].lengthUnits : MusicXMLWriter.divisions * 4
    }

    private func naturalWidth(measure: Int, in document: ScoreDocument) -> CGFloat {
        let table = onsetTable(measure: measure, in: document)
        let end = length(of: measure, in: document)
        var width = ScoreSystemLayout.measurePadLeft * sp

        for (index, entry) in table.enumerated() {
            let next = index + 1 < table.count ? table[index + 1].units : end
            width += CGFloat(min(entry.accidentals, 2)) * ScoreSystemLayout.accidentalWidth * sp
            width += gapWidth(units: next - entry.units)
        }

        width += ScoreSystemLayout.measurePadRight * sp

        return max(width, ScoreSystemLayout.minimumMeasureWidth * sp)
    }

    /// The x of each onset inside `[contentX, contentX + contentWidth)`, spaced as
    /// ``naturalWidth`` spaced them and scaled to fit.
    private func onsetXs(measure: Int, in document: ScoreDocument, contentX: CGFloat, contentWidth: CGFloat) -> [(units: Int, x: CGFloat)] {
        let table = onsetTable(measure: measure, in: document)
        let end = length(of: measure, in: document)
        var positions: [(Int, CGFloat)] = []
        var cursor = ScoreSystemLayout.measurePadLeft * sp

        for (index, entry) in table.enumerated() {
            cursor += CGFloat(min(entry.accidentals, 2)) * ScoreSystemLayout.accidentalWidth * sp
            positions.append((entry.units, cursor))
            let next = index + 1 < table.count ? table[index + 1].units : end
            cursor += gapWidth(units: next - entry.units)
        }

        let natural = max(cursor + ScoreSystemLayout.measurePadRight * sp, ScoreSystemLayout.minimumMeasureWidth * sp)
        let scale = contentWidth / natural

        var result = positions.map { (units: $0.0, x: contentX + $0.1 * scale) }
        result.append((units: end, x: contentX + contentWidth - ScoreSystemLayout.measurePadRight * sp * scale))

        return result
    }

    // MARK: - Lookups

    /// The system and box holding measure `index`.
    public func box(forMeasure index: Int) -> (system: System, box: MeasureBox)? {
        for system in systems {
            if let box = system.measures.first(where: { $0.index == index }) {
                return (system, box)
            }
        }

        return nil
    }

    /// The measure and the position in it under `point`, or nil off the music.
    public func hitTest(_ point: CGPoint) -> (measure: Int, units: Double)? {
        for system in systems where point.y >= system.frame.minY - ScoreSystemLayout.systemGap * sp / 2
            && point.y <= system.frame.maxY + ScoreSystemLayout.systemGap * sp / 2
        {
            for box in system.measures where point.x >= box.x && point.x < box.endX {
                return (box.index, box.units(forX: point.x))
            }

            if let first = system.measures.first, point.x < first.x {
                return (first.index, 0)
            }

            if let last = system.measures.last, point.x >= last.endX {
                return (last.index, Double(last.onsets.last?.units ?? 0))
            }
        }

        return nil
    }
}
