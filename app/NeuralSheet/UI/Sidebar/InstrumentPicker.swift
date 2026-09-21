import AppKit
import NeuralSheetCore
import SwiftUI

/// The instrument menu the inspector, the note card and the strip card share: the instruments
/// already in the mix first, with their colours, so moving notes onto a strip that exists is one
/// look away; then everything else.
enum InstrumentPicker {
    /// - Parameters:
    ///   - host: The popup the anchor is inside, if any. The menu is then its child and does not
    ///     take key, or the popup would close under it.
    ///   - current: Programs shown ticked (one, or none when the caller's selection disagrees).
    ///   - excluding: A program left out of the list -- the strip's own, on the strip card.
    @MainActor
    static func show(_ menu: PopupMenuPresenter,
                     from anchor: NSView,
                     host: PopupMenuPresenter?,
                     model: AppModel,
                     current: Set<Int>,
                     excluding: Int? = nil,
                     scale: CGFloat,
                     onChoose: @escaping (Int) -> Void) {
        guard let window = anchor.window else { return }

        let inMix = model.mixer.entries.map(\.info).filter { $0.program != excluding }
        let inMixPrograms = Set(inMix.map(\.program))
        let others = Instruments.all.filter { !inMixPrograms.contains($0.program) && $0.program != excluding }
        let width = PopupMenuPresenter.width(forTitles: Instruments.all.map(\.name), scale: scale)

        func row(_ info: InstrumentInfo, chip: Color?) -> MenuRow {
            MenuRow(title: info.name, isTicked: current == [info.program], chip: chip) {
                menu.dismiss()
                onChoose(info.program)
            }
        }

        let target = window.convertToScreen(anchor.convert(anchor.bounds, to: nil))

        host?.child = menu
        menu.show(targetScreenRect: target, in: window, width: width, scale: scale, placement: .alignedToTarget,
                  becomesKey: host == nil) {
            if !inMix.isEmpty {
                MenuSectionLabel(title: "IN THE MIX")

                ForEach(inMix, id: \.program) { info in
                    row(info, chip: Color(.sRGB, red: info.colour.r, green: info.colour.g, blue: info.colour.b, opacity: info.colour.a))
                }

                MenuSeparator()
                MenuSectionLabel(title: "ALL INSTRUMENTS")
            }

            ForEach(others, id: \.program) { info in
                row(info, chip: nil)
            }
        }
    }
}
