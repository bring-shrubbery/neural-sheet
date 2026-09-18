import Foundation
import NeuralSheetCore
import SwiftUI

/// The model panel's fixed extents (`ModelDownloadPanel.cpp`), in authored pixels. Multiply by the
/// UI scale at the point of use.
nonisolated enum ModelPanelMetrics {
    static let width: CGFloat = 440
    static let corner: CGFloat = 8

    /// Header, rows' contents and footer all start here, so they share one left edge.
    static let contentX: CGFloat = 20

    static let padTop: CGFloat = 16
    static let padBottom: CGFloat = 14
    static let titleHeight: CGFloat = 18
    static let subtitleHeight: CGFloat = 16
    static let headerGap: CGFloat = 10

    /// A row's background reaches closer to the panel's edge than its contents do.
    static let rowInsetX: CGFloat = 10
    static let rowHeight: CGFloat = 46
    static let rowGap: CGFloat = 2
    static let rowCorner: CGFloat = 6
    static let rowNameTop: CGFloat = 8
    static let rowMetaTop: CGFloat = 26
    static let rowLineHeight: CGFloat = 14
    static let checkboxGap: CGFloat = 12

    /// Wide enough for a progress bar, its percentage and the cross; every other control is
    /// right-aligned in the same column.
    static let controlColumnWidth: CGFloat = 172
    static let controlGap: CGFloat = 10
    static let percentWidth: CGFloat = 32

    static let footerGap: CGFloat = 10
    static let buttonHeight: CGFloat = 26
    static let buttonCorner: CGFloat = 6
    static let buttonPadLeft: CGFloat = 10
    static let buttonPadRight: CGFloat = 12
    static let buttonIconGap: CGFloat = 7
    static let iconSize: CGFloat = 13

    static let cancelHitSize: CGFloat = 16
    static let cancelGlyphSize: CGFloat = 9
    static let cancelCorner: CGFloat = 4

    static let progressBarHeight: CGFloat = 3
    static let barCorner: CGFloat = 2

    static let captionTracking: Double = 0.06

    /// The width the progress bar is left with once the percentage and the cross have taken theirs.
    static var progressBarWidth: CGFloat {
        controlColumnWidth - cancelHitSize - controlGap - percentWidth - controlGap
    }

    /// `ModelDownloadPanel::getIdealHeight()`: 252 for three rows.
    static var idealHeight: CGFloat {
        let rows = CGFloat(ModelSize.allCases.count)

        return padTop + titleHeight + subtitleHeight + headerGap + rows * rowHeight + (rows - 1) * rowGap
            + footerGap + buttonHeight + padBottom
    }
}

/// One row of the panel, read off the `AppModel` once per body so the drawing code below never
/// touches the model -- and so a preview can show every state without a model at all.
nonisolated struct ModelPanelRow: Equatable {
    let size: ModelSize
    var isInstalled: Bool
    var isInUse: Bool
    var phase: DownloadPhase

    /// What an earlier attempt left in the part file; a start from here resumes rather than
    /// downloads. Only meaningful while `phase` is `.idle`.
    var partialBytes: Int64 = 0

    /// `Status::getProgress`, in [0, 1].
    var progress: Double {
        guard case let .downloading(received, total) = phase, total > 0 else { return 0 }

        return min(1, max(0, Double(received) / Double(total)))
    }

    var percent: Int {
        Int((100 * progress).rounded())
    }

    var spec: ModelSpec {
        ModelManifest.spec(for: size)
    }
}

/// What the panel's controls do. Closures rather than the model, so the same panel previews
/// without one.
struct ModelPanelActions {
    var select: (ModelSize) -> Void = { _ in }
    var download: (ModelSize) -> Void = { _ in }
    var cancel: (ModelSize) -> Void = { _ in }
    var openFolder: () -> Void = {}
    var close: () -> Void = {}
}

/// The model panel over the `AppModel`: a row per size, an installed row picked by clicking it,
/// a missing one offering its download (`ModelDownloadPanel`).
///
/// The panel polls nothing itself: `AppModel` re-scans the models folder at 10 Hz and republishes
/// `installedModels` and `downloadPhases`, and the body follows them.
struct ModelPanel: View {
    let model: AppModel

    /// Part-file sizes, stat'ed once when the panel opens and again only when a row's own phase
    /// settles (to `.idle` or `.failed`) or the installed set moves. Never in `body`: the
    /// downloading row's phase changes on every chunk, and a stat per chunk per row on the main
    /// actor is what the C++ panel's 10 Hz poll avoided.
    @State private var partialBytes: [ModelSize: Int64] = [:]

    var body: some View {
        ModelPanelContent(rows: rows,
                          hasInstalledModel: !model.installedModels.isEmpty,
                          showsClose: !model.isModelPanelMandatory,
                          tooltipsEnabled: model.settings.tooltipsVisible,
                          actions: ModelPanelActions(select: { model.setModelSize($0) },
                                                     download: { model.startDownload($0) },
                                                     cancel: { model.cancelDownload($0) },
                                                     openFolder: { model.openModelsFolder() },
                                                     close: { model.isModelPanelOpen = false }))
            .onAppear {
                for size in ModelSize.allCases {
                    refreshPartialBytes(for: size)
                }
            }
            .onChange(of: model.downloadPhases) { old, new in
                for size in ModelSize.allCases {
                    let phase = new[size] ?? .idle

                    guard phase != old[size] ?? .idle else { continue }

                    // Only the settled phases show the button that reads the count; a chunk of
                    // progress on the downloading row is not a reason to stat the others.
                    switch phase {
                    case .idle, .failed: refreshPartialBytes(for: size)
                    case .downloading, .verifying: break
                    }
                }
            }
            .onChange(of: model.installedModels) { _, _ in
                for size in ModelSize.allCases {
                    refreshPartialBytes(for: size)
                }
            }
    }

    private var rows: [ModelPanelRow] {
        ModelSize.allCases.map { size in
            let isInstalled = model.installedModels.contains(size)
            let phase = model.downloadPhases[size] ?? .idle

            return ModelPanelRow(size: size,
                                 isInstalled: isInstalled,
                                 isInUse: model.modelSize == size,
                                 phase: phase,
                                 partialBytes: !isInstalled && phase == .idle ? partialBytes[size] ?? 0 : 0)
        }
    }

    private func refreshPartialBytes(for size: ModelSize) {
        partialBytes[size] = ModelPanel.partialBytes(for: size, in: model.paths)
    }

    /// The part file's size, or 0 without one -- the "Resume" the C++ panel read off
    /// `Status::downloadedBytes` outside a download. `AppModel` publishes no such thing, so it is
    /// read here, off the same path the downloader writes to.
    private static func partialBytes(for size: ModelSize, in paths: AppPaths) -> Int64 {
        let part = paths.models.appendingPathComponent(ModelManifest.spec(for: size).partFileName)
        let attributes = try? FileManager.default.attributesOfItem(atPath: part.path)

        return (attributes?[.size] as? NSNumber)?.int64Value ?? 0
    }
}

/// The panel as drawn: the title pair, the rows, the footer, on the popup surface. Fed values so
/// every state can be previewed side by side.
struct ModelPanelContent: View {
    let rows: [ModelPanelRow]
    let hasInstalledModel: Bool
    let showsClose: Bool
    var tooltipsEnabled: Bool = true
    var actions = ModelPanelActions()

    @Environment(\.uiScale) private var k

    var body: some View {
        let s = Scaled(k: k)
        let m = ModelPanelMetrics.self

        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.horizontal, s(m.contentX))

            VStack(spacing: s(m.rowGap)) {
                ForEach(rows, id: \.size) { row in
                    ModelPanelRowView(row: row, tooltipsEnabled: tooltipsEnabled, actions: actions)
                }
            }
            .padding(.horizontal, s(m.rowInsetX))
            .padding(.top, s(m.headerGap))

            footer
                .padding(.leading, s(m.contentX))
                .padding(.top, s(m.footerGap))
        }
        .padding(.top, s(m.padTop))
        .padding(.bottom, s(m.padBottom))
        .frame(width: s(m.width), alignment: .leading)
        .popupSurface(corner: s(m.corner))
    }

    // MARK: - Header

    private var header: some View {
        let s = Scaled(k: k)
        let m = ModelPanelMetrics.self

        return VStack(alignment: .leading, spacing: 0) {
            ZStack(alignment: .trailing) {
                Text(hasInstalledModel ? "Transcription model" : "No transcription model installed")
                    .font(Fonts.filename(k))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    // The title keeps clear of the cross's column whether or not the cross shows.
                    .padding(.trailing, s(m.cancelHitSize + m.controlGap))

                if showsClose {
                    ModelPanelCrossButton(tooltip: tip("Close"), action: actions.close)
                }
            }
            .frame(height: s(m.titleHeight))

            Text(hasInstalledModel ? "Tick the model to transcribe with." : "Download a model to start transcribing.")
                .font(Fonts.menuItem(k))
                .foregroundStyle(Theme.textMuted)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
                .frame(height: s(m.subtitleHeight))
        }
    }

    // MARK: - Footer

    private var footer: some View {
        ModelPanelLabelButton(title: "Open models folder",
                              fill: Theme.popupRowHover,
                              outline: Theme.popupBorder,
                              foreground: Theme.textButton,
                              iconColour: Theme.textIcon,
                              icon: Icons.FolderStroked(),
                              action: actions.openFolder)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func tip(_ text: String) -> String {
        tooltipsEnabled ? text : ""
    }
}

// MARK: - Rows

/// One size: checkbox, name and meta line, and whatever the right-hand column holds for its state.
private struct ModelPanelRowView: View {
    let row: ModelPanelRow
    let tooltipsEnabled: Bool
    let actions: ModelPanelActions

    @Environment(\.uiScale) private var k
    @State private var isHovered = false

    var body: some View {
        let s = Scaled(k: k)
        let m = ModelPanelMetrics.self
        let shape = RoundedRectangle(cornerRadius: s(m.rowCorner), style: .circular)

        HStack(spacing: 0) {
            MenuCheckbox(isTicked: row.isInUse)
                .opacity(row.isInstalled ? 1 : Theme.disabledAlpha)

            Color.clear
                .frame(width: s(m.checkboxGap))

            text
                .frame(maxWidth: .infinity, alignment: .leading)

            if !row.isInstalled {
                Color.clear
                    .frame(width: s(m.controlGap))

                controls
            }
        }
        .padding(.horizontal, s(m.contentX - m.rowInsetX))
        .frame(height: s(m.rowHeight))
        .frame(maxWidth: .infinity)
        .background(shape.fill(background))
        .contentShape(shape)
        .onHover { isHovered = $0 }
        .onTapGesture {
            if row.isInstalled, !row.isInUse {
                actions.select(row.size)
            }
        }
        .pointerStyle(row.isInstalled ? .link : nil)
    }

    private var background: Color {
        if row.isInUse {
            return Theme.accentFillActive
        }

        if row.isInstalled, isHovered {
            return Theme.popupRowHover
        }

        return .clear
    }

    /// The name at 8 px and the line under it at 26 px, each 14 px tall, as the C++ drew them.
    private var text: some View {
        let s = Scaled(k: k)
        let m = ModelPanelMetrics.self

        return VStack(alignment: .leading, spacing: 0) {
            Text(row.size.displayName)
                .font(row.isInUse ? Fonts.menuItemTicked(k) : Fonts.instrumentName(k))
                .foregroundStyle(row.isInUse ? Theme.popupItemTicked
                    : row.isInstalled ? Theme.popupItem : Theme.textMuted)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
                .frame(height: s(m.rowLineHeight))
                .padding(.top, s(m.rowNameTop))

            Text(meta)
                .font(Fonts.meta(k))
                .foregroundStyle(isFailed ? Theme.warn : Theme.textFaint)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
                .frame(height: s(m.rowLineHeight))
                .padding(.top, s(m.rowMetaTop - m.rowNameTop - m.rowLineHeight))
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }

    private var isFailed: Bool {
        if case .failed = row.phase, !row.isInstalled {
            return true
        }

        return false
    }

    private var meta: String {
        let spec = row.spec

        switch row.phase {
        case let .failed(message) where !row.isInstalled:
            return message

        case let .downloading(received, _) where !row.isInstalled:
            return "\(TimeFormat.fileSize(bytes: received)) of \(TimeFormat.fileSize(bytes: spec.byteSize))"

        case .verifying where !row.isInstalled:
            return "\(TimeFormat.fileSize(bytes: spec.byteSize)) of \(TimeFormat.fileSize(bytes: spec.byteSize))"

        default:
            // Two spaces each side of the dot, as `"  " + separatorDot() + "  "`.
            return "\(TimeFormat.fileSize(bytes: spec.byteSize))  \u{00B7}  \(row.size.hint)"
        }
    }

    // MARK: The right-hand column

    @ViewBuilder
    private var controls: some View {
        let s = Scaled(k: k)
        let m = ModelPanelMetrics.self

        switch row.phase {
        case .downloading:
            HStack(spacing: 0) {
                progressBar
                    .frame(width: s(m.progressBarWidth), height: s(m.progressBarHeight))

                Color.clear
                    .frame(width: s(m.controlGap))

                Text("\(row.percent)%")
                    .font(Fonts.statusBar(k))
                    .foregroundStyle(Theme.progressText)
                    .lineLimit(1)
                    .frame(width: s(m.percentWidth), alignment: .trailing)

                Color.clear
                    .frame(width: s(m.controlGap))

                ModelPanelCrossButton(
                    tooltip: tooltipsEnabled ? "Stop the download. Starting it again resumes where it stopped" : "",
                    action: { actions.cancel(row.size) })
            }
            .frame(width: s(m.controlColumnWidth), height: s(m.rowHeight))

        case .verifying:
            Text("VERIFYING")
                .font(Fonts.statusBar(k))
                .kerning(Fonts.tracking(m.captionTracking, pointSize: Fonts.Size.statusBar, scale: k))
                // Kerning trails the last glyph too; JUCE right-aligned the glyphs' own box.
                .padding(.trailing, -Fonts.tracking(m.captionTracking, pointSize: Fonts.Size.statusBar, scale: k))
                .foregroundStyle(Theme.progressText)
                .lineLimit(1)
                .frame(width: s(m.controlColumnWidth), height: s(m.rowHeight), alignment: .trailing)

        case .idle, .failed:
            // The Transcribe button's colours: it is the same call to action, one step earlier.
            ModelPanelLabelButton(title: downloadLabel,
                                  fill: Theme.ctaFill,
                                  outline: Theme.ctaBorder,
                                  foreground: Theme.ctaText,
                                  iconColour: Theme.ctaText,
                                  icon: Icons.DownloadStroked(),
                                  action: { actions.download(row.size) })
        }
    }

    private var downloadLabel: String {
        if case .failed = row.phase {
            return "Retry"
        }

        return row.partialBytes > 0 ? "Resume" : "Download"
    }

    private var progressBar: some View {
        let s = Scaled(k: k)
        let m = ModelPanelMetrics.self
        let shape = RoundedRectangle(cornerRadius: s(m.barCorner), style: .circular)
        let filled = s(m.progressBarWidth) * row.progress

        return ZStack(alignment: .leading) {
            shape.fill(Theme.progressTrack)

            if filled > 0 {
                shape.fill(Theme.progressFill)
                    .frame(width: max(filled, 2 * s(m.barCorner)))
            }
        }
    }
}

// MARK: - Buttons

/// A 13 px stroked icon and a `buttonLabel` caption in a 26 px outlined pill: the download button
/// and the folder button differ only in colours.
private struct ModelPanelLabelButton<Icon: Shape>: View {
    let title: String
    let fill: Color
    let outline: Color
    let foreground: Color
    let iconColour: Color
    let icon: Icon
    let action: () -> Void

    @Environment(\.uiScale) private var k

    var body: some View {
        let s = Scaled(k: k)
        let m = ModelPanelMetrics.self
        let shape = RoundedRectangle(cornerRadius: s(m.buttonCorner), style: .circular)

        FlatButton(idle: fill,
                   on: fill,
                   foregroundIdle: foreground,
                   foregroundOn: foreground,
                   corner: s(m.buttonCorner),
                   action: action) { _ in
            HStack(spacing: s(m.buttonIconGap)) {
                // Its own colour rather than the label's: the folder button's icon is `textIcon`
                // under a `textButton` caption. Neither button is ever "on", so hover leaves both.
                icon
                    .stroke(iconColour, style: Icons.strokeStyle(scale: k))
                    .frame(width: s(m.iconSize), height: s(m.iconSize))

                Text(title)
                    .font(Fonts.buttonLabel(k))
                    .lineLimit(1)
                    .fixedSize()
            }
            .padding(.leading, s(m.buttonPadLeft))
            .padding(.trailing, s(m.buttonPadRight))
            .frame(height: s(m.buttonHeight))
        }
        // strokeBorder, as the C++ inset the outline by half a pixel to keep it inside the fill.
        .overlay(shape.strokeBorder(outline, lineWidth: k))
    }
}

/// The 16 px cross that closes the panel and the one that stops a download: a 9 px glyph in a
/// transparent 4 px-cornered button that lights up on hover.
private struct ModelPanelCrossButton: View {
    let tooltip: String
    let action: () -> Void

    @Environment(\.uiScale) private var k

    var body: some View {
        let s = Scaled(k: k)
        let m = ModelPanelMetrics.self

        FlatButton(idle: .clear,
                   on: Theme.bgControlActive,
                   corner: s(m.cancelCorner),
                   action: action) { _ in
            Icons.CrossStroked()
                .stroke(style: Icons.strokeStyle(scale: k))
                .frame(width: s(m.cancelGlyphSize), height: s(m.cancelGlyphSize))
                .frame(width: s(m.cancelHitSize), height: s(m.cancelHitSize))
        }
        .tooltip(tooltip)
    }
}

// MARK: - Overlay

/// The panel where the root view shows it, with the scrim that closes it.
///
/// Nothing is drawn while the panel is closed, so the root can keep this in its `ZStack`
/// unconditionally. While the panel is mandatory (§3.2) there is no scrim: nothing may close it,
/// and the rest of the window -- loading audio, in particular -- stays usable underneath, as it
/// did in the original.
///
/// - Parameter anchor: The panel's top-leading corner in authored pixels, from the root's
///   top-leading corner. The default hangs it under the top bar; the original centred it on the
///   piano roll, which is `roll.midX - ModelPanelMetrics.width / 2` by
///   `roll.midY - ModelPanelMetrics.idealHeight / 2` in the same units.
struct ModelPanelOverlay: View {
    let model: AppModel
    var anchor = CGPoint(x: 0, y: 54)

    @Environment(\.uiScale) private var k

    var body: some View {
        let s = Scaled(k: k)

        ZStack(alignment: .topLeading) {
            if model.isModelPanelOpen {
                if !model.isModelPanelMandatory {
                    Color.clear
                        .contentShape(Rectangle())
                        .onTapGesture { model.isModelPanelOpen = false }
                }

                ModelPanel(model: model)
                    .padding(.leading, s(anchor.x))
                    .padding(.top, s(anchor.y))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

// MARK: - Previews

#if DEBUG
/// Every row state next to each other: the in-use row, an installed one, and a missing one in each
/// of its phases.
private let previewRows: [ModelPanelRow] = [
    ModelPanelRow(size: .small, isInstalled: true, isInUse: false, phase: .idle),
    ModelPanelRow(size: .medium, isInstalled: true, isInUse: true, phase: .idle),
    ModelPanelRow(size: .large, isInstalled: false, isInUse: false, phase: .idle),
]

private let previewBusyRows: [ModelPanelRow] = [
    ModelPanelRow(size: .small, isInstalled: false, isInUse: false, phase: .idle, partialBytes: 12_000_000),
    ModelPanelRow(size: .medium, isInstalled: false, isInUse: false,
                  phase: .downloading(received: 120_000_000, total: 618_442_496)),
    ModelPanelRow(size: .large, isInstalled: false, isInUse: false, phase: .verifying),
]

private let previewFailedRows: [ModelPanelRow] = [
    ModelPanelRow(size: .small, isInstalled: false, isInUse: false, phase: .idle),
    ModelPanelRow(size: .medium, isInstalled: false, isInUse: false,
                  phase: .failed(message: "Could not reach huggingface.co")),
    ModelPanelRow(size: .large, isInstalled: false, isInUse: false,
                  phase: .failed(message: "The download was corrupted. Try again")),
]

private struct ModelPanelPreview: View {
    let rows: [ModelPanelRow]
    let hasInstalledModel: Bool
    let showsClose: Bool
    var scale: CGFloat = 1

    var body: some View {
        ModelPanelContent(rows: rows, hasInstalledModel: hasInstalledModel, showsClose: showsClose)
            .uiScale(scale)
            .padding(60 * scale)
            .background(Theme.bgRoot)
    }
}

#Preview("Installed, in use") {
    FontRegistry.registerBundledFonts()

    return ModelPanelPreview(rows: previewRows, hasInstalledModel: true, showsClose: true)
}

#Preview("Downloading, verifying, resume") {
    FontRegistry.registerBundledFonts()

    return ModelPanelPreview(rows: previewBusyRows, hasInstalledModel: false, showsClose: false)
}

#Preview("Failed") {
    FontRegistry.registerBundledFonts()

    return ModelPanelPreview(rows: previewFailedRows, hasInstalledModel: false, showsClose: true)
}

#Preview("Mandatory, 1.5x") {
    FontRegistry.registerBundledFonts()

    return ModelPanelPreview(rows: previewFailedRows, hasInstalledModel: false, showsClose: false, scale: 1.5)
}
#endif
