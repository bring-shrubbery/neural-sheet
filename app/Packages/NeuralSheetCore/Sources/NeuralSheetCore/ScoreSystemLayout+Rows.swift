import Foundation

/// The vertical stacking of a system (score design §2): every part's staves, its lyric line and
/// its tab, with the gaps between.
extension ScoreSystemLayout {
    /// Every part's staves then its tab, stacked from `top`, with the gaps between. A part with
    /// words gets ``lyricLine`` more room under its bottom staff, before its tab or the next part
    /// (markers and lyrics design §2).
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

            if rowsOfPart > 0, part.hasLyrics {
                rows[rows.count - 1].lyricsBelow = true
                rowY += ScoreSystemLayout.lyricLine * sp
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
    /// the trailing part gap, plus the last part's lyric line when it ends on one, so the words
    /// stay inside the system.
    public static func systemHeight(for document: ScoreDocument, arrangement: ScoreArrangement, sp: CGFloat) -> CGFloat {
        guard let last = rows(for: document, top: 0, sp: sp).last else { return 0 }

        return last.bottomLineY + (last.lyricsBelow ? ScoreSystemLayout.lyricLine * sp : 0)
    }
}
