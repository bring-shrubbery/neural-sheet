import AppKit
import NeuralSheetCore
import SwiftUI

/// The row above the timeline (`NnToolbar`): what is loaded on the left, what can be done with the
/// transcription on the right.
///
/// Right to left: the bin and Re-transcribe (ours, the Edit toolbar's twin), each a
/// `toolbarButton` (28) tall with 12 between them. The Drag MIDI out, the Export button and the
/// EXPORT TEMPO pill NeuralNote had here are gone: File → Export MIDI… (⇧⌘E), with the tempo
/// asked for in its dialog, is how a transcription leaves the app.
struct Toolbar: View {
    let model: AppModel

    @Environment(\.uiScale) private var k
    @State private var clearMenu = PopupMenuPresenter()

    /// `NnToolbar.cpp` and `nn::metrics`, authored at 1x.
    enum Metrics {
        static let height: CGFloat = 44
        static let paddingSide: CGFloat = 14
        static let groupGap: CGFloat = 12
        static let buttonHeight: CGFloat = 28
        static let corner: CGFloat = 6
        static let iconSize: CGFloat = 13
        static let buttonPadX: CGFloat = 12
        static let iconLabelGap: CGFloat = 7
    }

    var body: some View {
        let s = Scaled(k: k)
        // The bin is live as soon as there is anything to throw away, audio with no transcription
        // included. Not while a run of either kind is in flight: stopping one is its own cancel.
        let canClear = (model.state == .audioLoaded || model.state == .populated) && model.regionJob == nil

        VStack(spacing: 0) {
            // The buttons sit at y 7 in the 43 px row above the border, as `withSizeKeepingCentre`
            // rounds them there.
            HStack(spacing: s(Metrics.groupGap)) {
                if let name = model.droppedFileName {
                    // Nothing at all when there is no file: the waveform's drop zone right below
                    // already says the window is empty.
                    Text(name)
                        .font(Fonts.filename(k))
                        .foregroundStyle(Theme.textFile)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    Spacer(minLength: 0)
                }

                // The same Re-transcribe the Edit toolbar has: a range can be marked in either tab.
                RetranscribeButton(model: model)
                clearButton(canClear: canClear)
            }
            .frame(height: s(Metrics.buttonHeight))
            .padding(.top, s(7))
            .padding(.bottom, s(8))
            .padding(.horizontal, s(Metrics.paddingSide))

            Rectangle()
                .fill(Theme.divSoft)
                .frame(height: k)
        }
        .frame(height: s(Metrics.height))
        .frame(maxWidth: .infinity)
        .background(Theme.bgRoot)
    }

    // MARK: - Clear

    private func clearButton(canClear: Bool) -> some View {
        let s = Scaled(k: k)

        return FlatButton(isEnabled: canClear,
                          idle: Theme.bgControlAlt,
                          on: Theme.bgControlActive,
                          foregroundIdle: Theme.textIconSoft,
                          foregroundOn: Theme.textPrimary,
                          corner: s(Metrics.corner),
                          action: model.clear) { _ in
            Icons.TrashStroked()
                .stroke(style: Icons.strokeStyle(scale: k))
                .frame(width: s(Metrics.iconSize), height: s(Metrics.iconSize))
                .frame(width: s(Metrics.buttonHeight), height: s(Metrics.buttonHeight))
        }
        .overlay(ClearButtonRightClickCatcher(isEnabled: canClear) { anchor in
            showClearMenu(from: anchor)
        })
        .tooltip("Clear audio and transcription | Shift + Backspace\nRight-click to clear the transcription only")
        .accessibilityLabel("Clear")
    }

    /// The bin's right-click menu: everything, or the transcription only.
    private func showClearMenu(from anchor: NSView) {
        let clearMenu = clearMenu
        let model = model
        let titles = ["Clear audio and transcription", "Clear transcription only"]
        let width = PopupMenuPresenter.width(forTitles: titles, scale: k)

        clearMenu.show(from: anchor, width: width, scale: k) {
            MenuRow(title: titles[0]) {
                clearMenu.dismiss()
                model.clear()
            }

            // Keeps the file loaded and the instrument selection with it, so the obvious next move
            // -- adjust the selection and run again -- does not start with re-dropping the audio.
            MenuRow(title: titles[1], isEnabled: model.state == .populated) {
                clearMenu.dismiss()
                model.clearTranscription()
            }
        }
    }
}

// MARK: - Tracked text

/// Letter-spaced text the way `nn::drawTrackedText` lays it out: glyph *i* shifted by
/// `i * em * pointSize`, which puts a gap after every glyph but the last. `kerning` on its own adds
/// one after the last glyph too, and that trailing gap is what would make a measured or
/// right-aligned label a fraction wide.
struct TrackedLabel: View {
    let string: String
    let em: Double
    let pointSize: CGFloat
    let font: Font
    let scale: CGFloat

    var body: some View {
        let spacing = Fonts.tracking(em, pointSize: pointSize, scale: scale)

        if string.count > 1 {
            let head = Text(String(string.dropLast())).kerning(spacing)
            let tail = Text(String(string.suffix(1)))

            Text("\(head)\(tail)")
                .font(font)
        } else {
            Text(string).font(font)
        }
    }
}

// MARK: - Right click

/// Catches the secondary click on the control it overlays and nothing else: every other event
/// falls through to the control underneath, so its own gestures and hover keep working. Named
/// apart from the sidebar's ``RightClickCatcher`` (`Controls/RightClickCatcher.swift`): that one
/// reports the window and a point for a floating panel, this one reports the view it caught the
/// click on and can be turned off.
private struct ClearButtonRightClickCatcher: NSViewRepresentable {
    let isEnabled: Bool
    let onRightClick: (NSView) -> Void

    func makeNSView(context: Context) -> CatcherView {
        let view = CatcherView(frame: .zero)
        view.isEnabled = isEnabled
        view.onRightClick = onRightClick

        return view
    }

    func updateNSView(_ nsView: CatcherView, context: Context) {
        nsView.isEnabled = isEnabled
        nsView.onRightClick = onRightClick
    }

    final class CatcherView: NSView {
        var isEnabled = true
        var onRightClick: ((NSView) -> Void)?

        /// The event being dispatched is the one `hitTest` is asked about, so the view can decline
        /// everything but a popup-menu click (`ModifierKeys::isPopupMenu`: right button, or
        /// control + left).
        override func hitTest(_ point: NSPoint) -> NSView? {
            guard isEnabled, let event = NSApp.currentEvent, Self.isPopupMenuClick(event) else {
                return nil
            }

            return super.hitTest(point)
        }

        override func rightMouseDown(with event: NSEvent) {
            onRightClick?(self)
        }

        override func mouseDown(with event: NSEvent) {
            if Self.isPopupMenuClick(event) {
                onRightClick?(self)
            } else {
                super.mouseDown(with: event)
            }
        }

        private static func isPopupMenuClick(_ event: NSEvent) -> Bool {
            switch event.type {
            case .rightMouseDown:
                return true
            case .leftMouseDown:
                return event.modifierFlags.contains(.control)
            default:
                return false
            }
        }
    }
}
