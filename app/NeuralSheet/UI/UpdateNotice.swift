import AppKit
import SwiftUI

/// The update-check notification (`UpdateCheck.cpp`, inventory §9): one line of text on the popup
/// surface, a "See update" button when there is one, and a cross.
///
/// Sized to its content, at most 449 wide, and placed by its parent in the timeline's bottom
/// trailing corner: `padX` in from the right and 10 px above the status bar (§1.2). A long
/// message ellipsises rather than running under the buttons. The model drops the notice at
/// `expiresAt`; while the pointer rests on the panel a 5 Hz tick pushes that out to at least three
/// seconds from now, and the cross drops it at once.
struct UpdateNoticeView: View {
    let model: AppModel
    let notice: UpdateNotice

    @Environment(\.uiScale) private var k
    @State private var isHovered = false

    /// `NeuralNoteMainView::resized`: the strip's authored width, and its gap to the status bar.
    static let maxWidth: CGFloat = 460 - MenuMetrics.padX
    static let bottomGap: CGFloat = 10

    /// Between the message, the button and the cross.
    private static let contentGap: CGFloat = 9

    /// The cross: the model panel's, which is gone; the status bar's cancel is drawn the same.
    private static let crossHitSize: CGFloat = 16
    private static let crossGlyphSize: CGFloat = 9
    private static let crossCorner: CGFloat = 4
    private static let buttonHeight: CGFloat = 24
    private static let buttonPadX: CGFloat = 12
    private static let buttonCorner: CGFloat = 6

    var body: some View {
        let s = Scaled(k: k)

        HStack(spacing: s(Self.contentGap)) {
            Text(notice.text)
                .font(Fonts.menuItem(k))
                .foregroundStyle(Theme.popupItem)
                .lineLimit(1)
                .truncationMode(.tail)

            if notice.showsSeeUpdate {
                seeUpdateButton
            }

            dismissButton
        }
        .padding(.horizontal, s(MenuMetrics.padX))
        .frame(height: s(MenuMetrics.rowHeight))
        // `nn::drawPopupSurface` only: the notification carries no shadow.
        .popupSurface(corner: s(MenuMetrics.corner), shadow: false)
        .onHover { isHovered = $0 }
        // The 5 Hz tick, running only while the pointer is on the panel.
        .task(id: isHovered) {
            guard isHovered else { return }

            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1.0 / UpdateCheck.hoverTickHz))

                guard !Task.isCancelled else { return }

                model.extendUpdateNoticeForHover()
            }
        }
        .frame(maxWidth: s(Self.maxWidth), alignment: .trailing)
        .padding(.trailing, s(MenuMetrics.padX))
        .padding(.bottom, s(Self.bottomGap))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(notice.text)
    }

    /// Accent-outlined, like Drag MIDI out: it is the one thing this notification is asking for.
    private var seeUpdateButton: some View {
        let s = Scaled(k: k)
        let shape = RoundedRectangle(cornerRadius: s(Self.buttonCorner), style: .circular)

        return FlatButton(idle: Theme.accentFillButton,
                          on: Theme.bgControlActive,
                          foregroundIdle: Theme.accentText,
                          foregroundOn: Theme.textBright,
                          corner: s(Self.buttonCorner),
                          action: { NSWorkspace.shared.open(UpdateCheck.latestReleasePage) }) { _ in
            Text("See update")
                .font(Fonts.buttonLabel(k))
                .fixedSize()
                .padding(.horizontal, s(Self.buttonPadX))
                .frame(height: s(Self.buttonHeight))
        }
        .overlay(shape.strokeBorder(Theme.accent, lineWidth: k))
        .accessibilityLabel("See update")
    }

    /// The same cross the status bar cancels a transcription with, for the same reason: ten
    /// seconds is generous, and there is no reason to wait it out.
    private var dismissButton: some View {
        let s = Scaled(k: k)

        return FlatButton(idle: .clear,
                          on: Theme.bgControlActive,
                          corner: s(Self.crossCorner),
                          action: model.dismissUpdateNotice) { _ in
            Icons.CrossStroked()
                .stroke(style: Icons.strokeStyle(scale: k))
                .frame(width: s(Self.crossGlyphSize), height: s(Self.crossGlyphSize))
                .frame(width: s(Self.crossHitSize), height: s(Self.crossHitSize))
        }
        .tooltip("Dismiss")
        .accessibilityLabel("Dismiss")
    }
}

// MARK: - Previews

#Preview("Update available") {
    FontRegistry.registerBundledFonts()

    let model = AppModel()
    let notice = UpdateNotice(text: UpdateCheck.newVersionText, showsSeeUpdate: true, expiresAt: .distantFuture)

    return ZStack(alignment: .bottomTrailing) {
        Theme.bgRoot
        UpdateNoticeView(model: model, notice: notice)
    }
    .frame(width: 1280, height: 800)
}

#Preview("On latest version") {
    FontRegistry.registerBundledFonts()

    let model = AppModel()
    let notice = UpdateNotice(text: UpdateCheck.latestVersionText, showsSeeUpdate: false, expiresAt: .distantFuture)

    return ZStack(alignment: .bottomTrailing) {
        Theme.bgRoot
        UpdateNoticeView(model: model, notice: notice)
    }
    .frame(width: 1280, height: 800)
}
