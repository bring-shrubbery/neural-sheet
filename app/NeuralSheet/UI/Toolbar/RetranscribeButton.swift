import AppKit
import NeuralSheetCore
import SwiftUI

/// The Edit toolbar's Re-transcribe (region design §6.4, §6.5): a label button live while a range
/// is marked, opening the popup that picks the instruments and runs; replaced in place by the
/// progress group while the run is in flight.
struct RetranscribeButton: View {
    let model: AppModel

    @Environment(\.uiScale) private var k
    @State private var menu = PopupMenuPresenter()
    @State private var anchor: NSView?

    private typealias Metrics = Toolbar.Metrics

    var body: some View {
        let s = Scaled(k: k)

        if model.regionJob != nil {
            RegionProgress(model: model)
        } else {
            FlatButton(isEnabled: model.canRetranscribe,
                       idle: Theme.bgControlAlt,
                       on: Theme.bgControlActive,
                       foregroundIdle: Theme.textButton,
                       foregroundOn: Theme.textBright,
                       corner: s(Metrics.corner),
                       action: showMenu) { _ in
                Text("Re-transcribe")
                    .font(Fonts.buttonLabel(k))
                    .fixedSize()
                    .padding(.horizontal, s(Metrics.buttonPadX))
                    .frame(height: s(Metrics.buttonHeight))
            }
            .tooltip("Re-transcribe the marked range")
            .background(AnchorCatcher { anchor = $0 })
        }
    }

    // MARK: - Popup

    /// Preset, the first time, to the instruments in the mix; after that to what was last chosen.
    private func showMenu() {
        guard let anchor, let range = model.editor.range else { return }

        if model.editor.retranscribeGroups == nil {
            model.setRetranscribeGroups(Self.groupsInMix(model))
        }

        let titles = Instruments.all.map(\.name) + ["Automatic (any instrument)"]
        let title = "\(TimeFormat.transport(range.lowerBound)) – \(TimeFormat.transport(range.upperBound))"

        // The run is the footer's button, pinned under the list: with 36 instruments to scroll
        // through, a last row would be off the bottom of the panel more often than not.
        menu.show(from: anchor,
                  width: PopupMenuPresenter.width(forTitles: titles, scale: k),
                  scale: k,
                  title: title,
                  footerView: AnyView(runButton(range: range))) {
            rows(range: range)
        }
    }

    /// Automatic, the mix's instruments ticked by default, then the rest. Every tick re-renders
    /// the rows in place so the panel stays open, as the sidebar's picker does.
    @ViewBuilder
    private func rows(range: Range<Double>) -> some View {
        let chosen = model.editor.retranscribeGroups ?? []
        let inMix = model.mixer.entries.compactMap { entry in entry.info.group == nil ? nil : entry.info }
        let inMixGroups = Set(inMix.compactMap(\.group))
        let others = Instruments.all.filter { info in info.group.map { !inMixGroups.contains($0) } ?? false }
        let model = model

        MenuSectionLabel(title: "INSTRUMENTS THE MODEL MAY USE")

        MenuRow(title: "Automatic (any instrument)", isTicked: chosen.isEmpty) {
            model.setRetranscribeGroups([])
            refreshRows(range: range)
        }

        if !inMix.isEmpty {
            MenuSeparator()
            MenuSectionLabel(title: "IN THE MIX")

            ForEach(inMix, id: \.program) { info in
                if let group = info.group {
                    MenuRow(title: info.name, isTicked: chosen.contains(group), chip: Color(info.colour)) {
                        model.toggleRetranscribeGroup(group)
                        refreshRows(range: range)
                    }
                }
            }
        }

        MenuSeparator()
        MenuSectionLabel(title: "ALL INSTRUMENTS")

        ForEach(others, id: \.program) { info in
            if let group = info.group {
                MenuRow(title: info.name, isTicked: chosen.contains(group)) {
                    model.toggleRetranscribeGroup(group)
                    refreshRows(range: range)
                }
            }
        }
    }

    /// The footer's primary button: a solid accent fill with dark text, the toolbar's button
    /// height, the panel's width. Runs with whatever the rows have ticked and closes the popup.
    private func runButton(range: Range<Double>) -> some View {
        let s = Scaled(k: k)
        let menu = menu
        let model = model

        return FlatButton(idle: Theme.accent,
                          on: Theme.accent,
                          foregroundIdle: Theme.bgRoot,
                          foregroundOn: Theme.bgRoot,
                          corner: s(Metrics.corner),
                          action: {
                              menu.dismiss()
                              model.retranscribe(range: range, groups: model.editor.retranscribeGroups ?? [])
                          }) { _ in
            Text("Re-transcribe")
                .font(Fonts.buttonLabel(k))
                .frame(maxWidth: .infinity)
                .frame(height: s(Metrics.buttonHeight))
        }
    }

    /// Re-renders the open panel's rows after a tick, so it shows the new ticks without closing.
    /// A method rather than a nested function: a `@ViewBuilder` body holds views, not declarations.
    private func refreshRows(range: Range<Double>) {
        menu.refresh { rows(range: range) }
    }

    /// The named groups of the instruments in the mix; a `program_<n>` has none and is skipped.
    static func groupsInMix(_ model: AppModel) -> [InstrumentGroup] {
        model.mixer.entries.compactMap(\.info.group)
    }
}

/// The toolbar's progress group while a region run is in flight (region design §6.5).
struct RegionProgress: View {
    let model: AppModel

    static let caption = "RE-TRANSCRIBING"

    var body: some View {
        ProgressGroup(caption: Self.caption,
                      progress: model.regionJob?.progress ?? 0,
                      cancelling: model.regionJob?.cancelLatched ?? false,
                      cancelTooltip: "Cancel re-transcription",
                      onCancel: model.cancelRegionTranscription)
    }
}

private extension Color {
    /// The model's colour type as SwiftUI's, for the chips. File scope, as the strip and the
    /// inspector keep their own copies: two visible overloads would collide.
    init(_ rgba: NeuralSheetCore.RGBA) {
        self.init(.sRGB, red: rgba.r, green: rgba.g, blue: rgba.b, opacity: rgba.a)
    }
}
