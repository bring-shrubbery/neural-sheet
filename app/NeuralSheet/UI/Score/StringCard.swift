import AppKit
import NeuralSheetCore
import SwiftUI

/// A tab note's strings (arrangement design §4): opened by a right-click on its fret number.
/// Every string with the fret the note would take there, top tab line first as on the page,
/// impossible ones marked in the warning colour, the current one ticked, and Automatic. A menu's
/// rows on the menu's surface, in the note card's floating panel.
struct StringCard: View {
    let model: AppModel
    let hit: TabHit
    /// The note's sounding pitch.
    let pitch: Int
    /// The panel this card is in, closed by a choice.
    let host: PopupMenuPresenter

    @Environment(\.uiScale) private var k

    var body: some View {
        let display = model.arrangement.display(for: hit.program)
        let tab = display.tab
        let manual = display.strings[hit.id]
        let strings = tab.map { Array($0.tuning.enumerated().reversed()) } ?? []
        let titles = [Self.automatic] + strings.map { title(string: $0.offset, open: $0.element, count: tab?.tuning.count ?? 0) }

        MenuPanel(width: PopupMenuPresenter.width(forTitles: titles, scale: k)) {
            MenuRow(title: Self.automatic, isTicked: manual == nil) {
                host.dismiss()
                model.setString(nil, program: hit.program, id: hit.id)
            }

            if let tab {
                MenuSeparator()

                ForEach(strings, id: \.offset) { string, open in
                    let fret = pitch - open
                    let playable = fret >= 0 && fret <= tab.frets

                    MenuRow(title: title(string: string, open: open, count: tab.tuning.count),
                            isTicked: manual == string || (manual == nil && hit.string == string),
                            chip: playable ? nil : Theme.warn) {
                        host.dismiss()
                        model.setString(string, program: hit.program, id: hit.id)
                    }
                }
            }
        }
    }

    /// "String 1 (E): fret 5", numbered from the top tab line as players count them; `string`
    /// is the tab's index, 0 being the bottom line.
    private func title(string: Int, open: Int, count: Int) -> String {
        let number = count - string
        let tuning = TuningPreset.label(for: [open])
        let fret = pitch - open

        return String(localized: "String \(number) (\(tuning)): fret \(fret)",
                      comment: "String card: a string, its open note and the fret the note takes on it, e.g. \"String 1 (E): fret 5\"")
    }

    private static var automatic: String {
        String(localized: "Automatic", comment: "String card: let the tab choose the string")
    }
}
