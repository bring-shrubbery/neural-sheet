import NeuralSheetCore
import UIKit

/// The touch score as VoiceOver reads it (a11y design §2, sub-issue J): the Mac's
/// `ScoreView+Accessibility` over `UIAccessibilityElement`. In reading order, top to bottom: each
/// system as a heading -- "System 2, bars 5 to 8", so the headings rotor jumps a line at a time --
/// followed by the notes, chords and rests of its staves left to right, "E4 G4, quarter note,
/// Piano, bar 5". A double tap seeks there, as a tap does; the actions rotor opens the part's
/// card, as a tap on its name does. The tab rows repeat their staff's notes and are left out.
///
/// The elements are made when VoiceOver first asks and dropped with the layout.
extension ScoreTouchView {
    /// Called once from `init`.
    func installAccessibility() {
        isAccessibilityElement = false
        accessibilityLabel = String(localized: "Score", comment: "VoiceOver: the Score tab's sheet music")
        accessibilityIdentifier = "score"
        accessibilityContainerType = .semanticGroup
    }

    override var accessibilityElements: [Any]? {
        get {
            if let accessibilityScoreElements { return accessibilityScoreElements }

            let elements = makeAccessibilityElements()
            accessibilityScoreElements = elements

            return elements
        }
        set {}
    }

    /// The layout changed: the next ask makes the elements again.
    func invalidateAccessibilityElements() {
        guard accessibilityScoreElements != nil else { return }

        accessibilityScoreElements = nil

        if UIAccessibility.isVoiceOverRunning {
            UIAccessibility.post(notification: .layoutChanged, argument: nil)
        }
    }

    // MARK: - Elements

    private func makeAccessibilityElements() -> [DrawnTouchElement] {
        guard let layout = canvas.painter.layout else { return [] }

        let document = canvas.painter.document

        return layout.systems.enumerated().flatMap { index, system in
            [systemElement(index, system, document: document)] + pieceElements(in: system, sp: layout.sp, document: document)
        }
    }

    private func systemElement(_ index: Int, _ system: ScoreSystemLayout.System, document: ScoreDocument) -> DrawnTouchElement {
        let first = (system.measures.first?.index ?? 0) + document.firstBar + 1
        let last = (system.measures.last?.index ?? 0) + document.firstBar + 1
        let label = String(localized: "System \(index + 1), bars \(first) to \(last)",
                           comment: "VoiceOver: one line of the score, e.g. \"System 2, bars 5 to 8\"")
        let frame = system.frame
        let element = DrawnTouchElement(in: scrollView, container: self, traits: .header, rect: { frame }, label: { label })

        element.didBecomeFocused = { [weak self] in self?.scrollToShow(frame) }

        return element
    }

    /// Every piece of every notation staff in the system, by x, then top to bottom.
    private func pieceElements(in system: ScoreSystemLayout.System, sp: CGFloat, document: ScoreDocument) -> [DrawnTouchElement] {
        var placed: [(x: CGFloat, row: Int, element: DrawnTouchElement)] = []

        for (rowIndex, row) in system.rows.enumerated() {
            guard case let .staff(staffIndex, _) = row.kind, document.parts.indices.contains(row.partIndex) else { continue }

            let part = document.parts[row.partIndex]

            guard part.staves.indices.contains(staffIndex) else { continue }

            let measures = part.staves[staffIndex].measures

            for box in system.measures where measures.indices.contains(box.index) {
                for piece in measures[box.index].pieces {
                    let x = box.x(forUnits: Double(piece.startUnits))
                    let frame = CGRect(x: x - sp, y: row.topLineY - 2 * sp, width: 2.5 * sp, height: row.height + 4 * sp)
                    let label = ScoreSpeech.description(of: piece, part: CoreNames.localized(part.name),
                                                        bar: box.index + document.firstBar + 1)
                    let element = DrawnTouchElement(in: scrollView, container: self, traits: .button, rect: { frame }, label: { label })
                    let measure = box.index
                    let units = Double(piece.startUnits)
                    let program = part.program

                    element.press = { [weak self] in
                        guard let self else { return false }

                        seek(measure: measure, units: units)
                        return true
                    }
                    element.actions = { [weak self] in
                        [UIAccessibilityCustomAction(String(localized: "Open Part Card", comment: "VoiceOver action on a note in the score (iOS): open its part's display sheet, as a tap on the part's name does")) {
                            self?.onPartName?(program)
                        }]
                    }
                    element.didBecomeFocused = { [weak self] in self?.scrollToShow(frame) }

                    placed.append((x, rowIndex, element))
                }
            }
        }

        return placed.sorted { $0.x != $1.x ? $0.x < $1.x : $0.row < $1.row }.map(\.element)
    }

    // MARK: - Actions

    private func seek(measure: Int, units: Double) {
        model.seek(toSeconds: canvas.painter.document.seconds(atMeasure: measure, units: units, grid: model.editor.grid))
        updateCursor()
    }

    /// VoiceOver's cursor went to something off screen: the score scrolls to bring it in, a
    /// little room above it.
    private func scrollToShow(_ frame: CGRect) {
        let visible = CGRect(origin: scrollView.contentOffset, size: scrollView.bounds.size)

        guard !visible.contains(frame) else { return }

        let sp = canvas.painter.layout?.sp ?? 8
        let y = min(max(0, frame.minY - 3 * sp), maxOffsetY)
        let x = min(max(0, frame.midX - visible.width / 2), max(0, scrollView.contentSize.width - visible.width))

        scrollView.contentOffset = CGPoint(x: canvas.contentBounds.width > bounds.width ? x : 0, y: y)
    }
}
