import AppKit
import NeuralSheetCore

/// The score as VoiceOver reads it (a11y design §2): its systems as groups, top to bottom, each
/// holding the notes, chords and rests of its staves left to right -- "E4 G4, quarter note,
/// Piano, bar 5" -- and a press on one seeks there, as a click does. The tab rows repeat their
/// staff's notes and are left out.
///
/// The systems are made when VoiceOver first asks and dropped with the layout; a system's notes
/// only when VoiceOver goes into it.
extension ScoreView: KeyboardFocusableView {
    override func isAccessibilityElement() -> Bool { true }

    override func accessibilityRole() -> NSAccessibility.Role? { .group }

    override func accessibilityLabel() -> String? {
        String(localized: "Score", comment: "VoiceOver: the Score tab's sheet music")
    }

    override func accessibilityChildren() -> [Any]? {
        if let accessibilitySystems { return accessibilitySystems }

        guard let layout else { return [] }

        let systems = layout.systems.enumerated().map { index, system in systemElement(index, system, sp: layout.sp) }
        accessibilitySystems = systems

        return systems
    }

    func invalidateAccessibilitySystems() {
        guard accessibilitySystems != nil else { return }

        accessibilitySystems = nil
        NSAccessibility.post(element: self, notification: .layoutChanged)
    }

    // MARK: - Elements

    private func systemElement(_ index: Int, _ system: ScoreSystemLayout.System, sp: CGFloat) -> DrawnElement {
        let first = (system.measures.first?.index ?? 0) + document.firstBar + 1
        let last = (system.measures.last?.index ?? 0) + document.firstBar + 1
        let label = String(localized: "System \(index + 1), bars \(first) to \(last)",
                           comment: "VoiceOver: one line of the score, e.g. \"System 2, bars 5 to 8\"")
        let element = DrawnElement(in: self, role: .group, rect: { system.frame }, label: { label })

        var notes: [DrawnElement]?

        element.children = { [weak self, weak element] in
            if let notes { return notes }

            guard let self, let element else { return [] }

            let made = pieceElements(in: system, sp: sp, container: element)
            notes = made

            return made
        }

        return element
    }

    /// Every piece of every notation staff in the system, by x, then top to bottom.
    private func pieceElements(in system: ScoreSystemLayout.System, sp: CGFloat, container: DrawnElement) -> [DrawnElement] {
        var placed: [(x: CGFloat, row: Int, element: DrawnElement)] = []

        for (rowIndex, row) in system.rows.enumerated() {
            guard case let .staff(staffIndex, _) = row.kind, document.parts.indices.contains(row.partIndex) else { continue }

            let part = document.parts[row.partIndex]

            guard part.staves.indices.contains(staffIndex) else { continue }

            let measures = part.staves[staffIndex].measures

            for box in system.measures where measures.indices.contains(box.index) {
                for piece in measures[box.index].pieces {
                    let x = box.x(forUnits: Double(piece.startUnits))
                    let frame = CGRect(x: x - sp, y: row.topLineY - 2 * sp, width: 2.5 * sp, height: row.height + 4 * sp)
                    let label = ScoreSpeech.description(of: piece, part: CoreNames.localized(part.name), bar: box.index + document.firstBar + 1)
                    let element = DrawnElement(in: self, role: .button,
                                               roleDescription: piece.isRest
                                                   ? String(localized: "rest", comment: "VoiceOver: what a rest in the score is")
                                                   : String(localized: "note", comment: "VoiceOver: what a note in the score is"),
                                               rect: { frame }, label: { label })
                    let measure = box.index
                    let units = Double(piece.startUnits)

                    element.container = container
                    element.press = { [weak self] in
                        guard let self, let onSeek else { return false }

                        onSeek(measure, units)
                        return true
                    }

                    placed.append((x, rowIndex, element))
                }
            }
        }

        return placed.sorted { $0.x != $1.x ? $0.x < $1.x : $0.row < $1.row }.map(\.element)
    }

    // MARK: - Keyboard focus

    override var acceptsFirstResponder: Bool { acceptsKeyboardFocus }

    override func drawFocusRingMask() {
        NSBezierPath(rect: focusRingRect).fill()
    }

    override var focusRingMaskBounds: NSRect { focusRingRect }
}
