import AppKit
import NeuralSheetCore
import SwiftUI

/// The row above the timeline (`NnToolbar`): what is loaded on the left, what can be done with the
/// transcription on the right.
///
/// Right to left: the bin, Drag MIDI out, Export MIDI out and the EXPORT TEMPO pill, each a
/// `toolbarButton` (28) tall with 12 between them. The export group is dimmed rather than absent
/// before there is a transcription to export: it holds its place either way, and an empty gap
/// there reads as something failing to draw.
struct Toolbar: View {
    let model: AppModel

    @Environment(\.uiScale) private var k
    @State private var clearMenu = PopupMenuPresenter()
    @State private var dragHovered = false
    @State private var dragPressed = false

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
        static let pillPadding: CGFloat = 10
        static let pillGap: CGFloat = 8
        static let spinnerWidth: CGFloat = 7
        static let spinnerHeight: CGFloat = 4
        static let spinnerGap: CGFloat = 2
        static let labelTracking: Double = 0.09
    }

    var body: some View {
        let s = Scaled(k: k)
        let canExport = model.canExport
        // The bin is live as soon as there is anything to throw away, audio with no transcription
        // included. Not while a run is in flight: stopping one is the status bar's cancel.
        let canClear = model.state == .audioLoaded || model.state == .populated

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

                tempoPill(canExport: canExport)
                exportButton(canExport: canExport)
                dragButton(canExport: canExport)
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

    // MARK: - Export tempo

    private func tempoPill(canExport: Bool) -> some View {
        let s = Scaled(k: k)

        return HStack(spacing: 0) {
            TrackedText(string: "EXPORT TEMPO",
                        em: Metrics.labelTracking,
                        pointSize: Fonts.Size.pillLabel,
                        font: Fonts.pillLabel(k),
                        scale: k)
                .foregroundStyle(Theme.textDim)
                .fixedSize()

            Spacer().frame(width: s(Metrics.pillGap))

            TempoField(model: model, isEnabled: canExport)

            Spacer().frame(width: s(Metrics.pillGap))

            // Stacked triangles rather than a spinner control: the value is typed, and these say
            // the field is a number without pretending to be a second way of setting it.
            VStack(spacing: s(Metrics.spinnerGap)) {
                Icons.TriangleUp()
                    .fill(Theme.textDim)
                    .frame(width: s(Metrics.spinnerWidth), height: s(Metrics.spinnerHeight))
                Icons.TriangleDown()
                    .fill(Theme.textDim)
                    .frame(width: s(Metrics.spinnerWidth), height: s(Metrics.spinnerHeight))
            }
        }
        .padding(.horizontal, s(Metrics.pillPadding))
        .frame(height: s(Metrics.buttonHeight))
        .background(RoundedRectangle(cornerRadius: s(Metrics.corner), style: .circular).fill(Theme.bgControlAlt))
        .opacity(canExport ? 1 : Theme.disabledAlpha)
    }

    // MARK: - Export

    private func exportButton(canExport: Bool) -> some View {
        let s = Scaled(k: k)

        return FlatButton(isEnabled: canExport,
                          idle: Theme.bgControlAlt,
                          on: Theme.bgControlActive,
                          foregroundIdle: Theme.textButton,
                          foregroundOn: Theme.textBright,
                          corner: s(Metrics.corner),
                          action: model.exportMidi) { _ in
            HStack(spacing: s(Metrics.iconLabelGap)) {
                Icons.FolderStroked()
                    .stroke(Theme.textIconSoft, style: Icons.strokeStyle(scale: k))
                    .frame(width: s(Metrics.iconSize), height: s(Metrics.iconSize))

                Text("Export MIDI out")
                    .font(Fonts.buttonLabel(k))
                    .fixedSize()
            }
            .padding(.horizontal, s(Metrics.buttonPadX))
            .frame(height: s(Metrics.buttonHeight))
        }
        .tooltip("Write the transcribed MIDI to a file")
        .accessibilityLabel("Export MIDI out")
    }

    // MARK: - Drag

    /// The one accent-outlined control in the window: this is the primary way a transcription
    /// leaves the app. There is no plain-click action.
    ///
    /// Not a `FlatButton`: its press gesture would take the mouse-down and the platform drag would
    /// never start. The surface is drawn here with the same `Theme.surface` / `Theme.foreground`
    /// rules every button uses, from the hover and press that `MidiDragSource` -- an AppKit view
    /// on top -- reports; that view owns the mouse, the cursor and the drag session.
    private func dragButton(canExport: Bool) -> some View {
        let s = Scaled(k: k)
        let shape = RoundedRectangle(cornerRadius: s(Metrics.corner), style: .circular)
        let state = ButtonVisualState(isHovered: canExport && dragHovered,
                                      isPressed: canExport && dragPressed,
                                      isOn: false,
                                      isEnabled: canExport)
        let surface = Theme.surface(idle: Theme.accentFillButton,
                                    on: Theme.bgControlActive,
                                    isOn: false,
                                    isHovered: state.isHovered,
                                    isPressed: state.isPressed,
                                    isEnabled: canExport)
        let foreground = Theme.foreground(idle: Theme.accentText,
                                          on: Theme.textBright,
                                          isOn: false,
                                          isHovered: state.isHovered)

        return HStack(spacing: s(Metrics.iconLabelGap)) {
            Icons.DownloadStroked()
                .stroke(foreground, style: Icons.strokeStyle(scale: k))
                .frame(width: s(Metrics.iconSize), height: s(Metrics.iconSize))

            Text("Drag MIDI out")
                .font(Fonts.buttonLabel(k))
                .foregroundStyle(foreground)
                .fixedSize()
        }
        .padding(.horizontal, s(Metrics.buttonPadX))
        .frame(height: s(Metrics.buttonHeight))
        .background(shape.fill(surface))
        // strokeBorder, as JUCE insets the outline by half a pixel so the 1 px line lands inside
        // the fill.
        .overlay(shape.strokeBorder(Theme.accent, lineWidth: k))
        .opacity(canExport ? 1 : Theme.disabledAlpha)
        .overlay(MidiDragSource(isEnabled: canExport,
                                fileURL: { model.writeMidiForDrag() },
                                onHover: { dragHovered = $0 },
                                onPress: { dragPressed = $0 }))
        .tooltip("Drag the transcribed MIDI into your DAW")
        .accessibilityLabel("Drag MIDI out")
        .accessibilityAddTraits(.isButton)
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
        .overlay(RightClickCatcher(isEnabled: canClear) { anchor in
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
struct TrackedText: View {
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
/// falls through to the control underneath, so its own gestures and hover keep working.
private struct RightClickCatcher: NSViewRepresentable {
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

// MARK: - MIDI drag source

/// The AppKit view over the Drag MIDI out button that starts the external file drag
/// (`MidiFileDrag`, `performExternalDragDropOfFiles`). It draws nothing; the SwiftUI surface
/// underneath is what is seen, and it is told about hover and press so it can paint them.
///
/// The mouse-down is taken here, where no SwiftUI gesture can pre-empt it. Once the pointer has
/// moved a few points the file is written and `beginDraggingSession` starts the platform drag with
/// the file's URL on the pasteboard and the file's own icon under the pointer, as the original did.
/// The drag session swallows the mouse-up, so the press is released when the session ends.
struct MidiDragSource: NSViewRepresentable {
    let isEnabled: Bool
    /// Called as the drag starts; nil means there is nothing to drag (the model has said why).
    let fileURL: () -> URL?
    let onHover: (Bool) -> Void
    let onPress: (Bool) -> Void

    /// Points the pointer must travel before a drag begins, so a click never starts one.
    static let dragThreshold: CGFloat = 3

    func makeNSView(context: Context) -> SourceView {
        let view = SourceView(frame: .zero)
        configure(view)

        return view
    }

    func updateNSView(_ nsView: SourceView, context: Context) {
        configure(nsView)
    }

    private func configure(_ view: SourceView) {
        view.isEnabled = isEnabled
        view.fileURL = fileURL
        view.onHover = onHover
        view.onPress = onPress
        view.window?.invalidateCursorRects(for: view)
    }

    final class SourceView: NSView, NSDraggingSource {
        var isEnabled = true {
            didSet {
                if !isEnabled, isPressed {
                    setPressed(false)
                }
            }
        }

        var fileURL: () -> URL? = { nil }
        var onHover: (Bool) -> Void = { _ in }
        var onPress: (Bool) -> Void = { _ in }

        /// Set by a test harness to observe the session start without a live pointer.
        var onSessionBegin: ((URL) -> Void)?

        private var tracking: NSTrackingArea?
        private var pressOrigin: NSPoint?
        private var isPressed = false
        private var sessionActive = false

        override var acceptsFirstResponder: Bool { false }

        /// Nothing is drawn: the surface is SwiftUI's.
        override func draw(_ dirtyRect: NSRect) {}

        /// The whole button, whenever it is live; nothing at all when it is not, so a disabled
        /// button neither reacts nor changes the cursor.
        override func hitTest(_ point: NSPoint) -> NSView? {
            isEnabled ? super.hitTest(point) : nil
        }

        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        // MARK: Hover and cursor

        override func updateTrackingAreas() {
            super.updateTrackingAreas()

            if let tracking {
                removeTrackingArea(tracking)
            }

            let area = NSTrackingArea(rect: .zero,
                                      options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                      owner: self,
                                      userInfo: nil)
            addTrackingArea(area)
            tracking = area
        }

        override func mouseEntered(with event: NSEvent) {
            if isEnabled {
                onHover(true)
            }
        }

        override func mouseExited(with event: NSEvent) {
            onHover(false)
        }

        /// `NnFlatButton`'s pointing hand, only while the button is live.
        override func resetCursorRects() {
            if isEnabled {
                addCursorRect(bounds, cursor: .pointingHand)
            }
        }

        // MARK: Mouse

        override func mouseDown(with event: NSEvent) {
            guard isEnabled else { return }

            pressOrigin = convert(event.locationInWindow, from: nil)
            setPressed(true)
        }

        override func mouseDragged(with event: NSEvent) {
            guard isEnabled, let origin = pressOrigin, !sessionActive else { return }

            let point = convert(event.locationInWindow, from: nil)

            guard hypot(point.x - origin.x, point.y - origin.y) >= MidiDragSource.dragThreshold else { return }

            pressOrigin = nil
            beginDrag(with: event, at: point)
        }

        override func mouseUp(with event: NSEvent) {
            pressOrigin = nil
            setPressed(false)
        }

        private func setPressed(_ pressed: Bool) {
            guard pressed != isPressed else { return }

            isPressed = pressed
            onPress(pressed)
        }

        // MARK: The session

        /// `MidiFileDrag::mouseDown`: the file is written as the drag starts, and its own icon is
        /// what travels under the pointer, in a 32 px frame centred on it.
        private func beginDrag(with event: NSEvent, at point: NSPoint) {
            guard let url = fileURL() else {
                setPressed(false)
                return
            }

            let item = NSDraggingItem(pasteboardWriter: url as NSURL)
            item.setDraggingFrame(CGRect(x: point.x - 16, y: point.y - 16, width: 32, height: 32),
                                  contents: NSWorkspace.shared.icon(forFile: url.path))

            onSessionBegin?(url)
            sessionActive = true

            let session = beginDraggingSession(with: [item], event: event, source: self)
            session.animatesToStartingPositionsOnCancelOrFail = true
        }

        func draggingSession(_ session: NSDraggingSession,
                             sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
            .copy
        }

        /// The mouse-up that would normally end the press went to the drag session instead.
        func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
            sessionActive = false
            pressOrigin = nil
            setPressed(false)
        }
    }
}

// MARK: - Popup menu

/// A `MenuPanel` shown the way `PopupMenu::showMenuAsync` with a target component placed it: in its
/// own window, left-aligned with the control, below it when there is room and above it otherwise,
/// dismissed by a click anywhere else (which is swallowed), by Escape or by the app deactivating.
///
/// Its own window rather than an overlay in the view tree because the menu can hang below the
/// bottom of the window it is opened from.
@MainActor final class PopupMenuPresenter {
    private var panel: NSPanel?
    private var monitors: [Any] = []
    private var observers: [NSObjectProtocol] = []

    /// `getIdealPopupMenuItemSize`: the widest title plus the paddings and the tick column, never
    /// narrower than the minimum. Authored units in, scaled points out.
    static func width(forTitles titles: [String], scale: CGFloat) -> CGFloat {
        let font = NSFont(name: Fonts.Name.interRegular, size: Fonts.Size.menuItem)
            ?? NSFont.systemFont(ofSize: Fonts.Size.menuItem)
        let tickColumn = MenuMetrics.checkboxSize + MenuMetrics.padX

        let widest = titles
            .map { ($0 as NSString).size(withAttributes: [.font: font]).width }
            .max() ?? 0

        return max(MenuMetrics.minWidth, ceil(widest) + 2 * MenuMetrics.padX + tickColumn) * scale
    }

    func show<Rows: View>(from anchor: NSView,
                          width: CGFloat,
                          scale: CGFloat,
                          @ViewBuilder rows: () -> Rows) {
        dismiss()

        guard let window = anchor.window else { return }

        let rows = rows()
        let hosting = KeyHostingView(rootView: MenuPanel(width: width) { rows }.uiScale(scale))
        hosting.sizingOptions = []

        let size = hosting.fittingSize
        hosting.frame = CGRect(origin: .zero, size: size)
        hosting.autoresizingMask = [.width, .height]

        let target = window.convertToScreen(anchor.convert(anchor.bounds, to: nil))
        let frame = Self.frame(size: size, target: target, scale: scale)

        let menu = MenuWindow(contentRect: frame,
                              styleMask: [.borderless, .nonactivatingPanel],
                              backing: .buffered,
                              defer: false)
        menu.contentView = hosting
        menu.isOpaque = false
        menu.backgroundColor = .clear
        menu.hasShadow = true
        menu.level = .popUpMenu
        menu.hidesOnDeactivate = true
        menu.animationBehavior = .none
        menu.collectionBehavior = [.transient, .ignoresCycle, .fullScreenAuxiliary]
        menu.isReleasedWhenClosed = false

        window.addChildWindow(menu, ordered: .above)
        menu.makeKeyAndOrderFront(nil)

        panel = menu

        monitors = [
            NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] event in
                guard let self, let panel = self.panel else { return event }

                if event.window === panel {
                    return event
                }

                // Swallowed, as the modal menu swallowed it: the click closes the menu and does
                // nothing else.
                self.dismiss()

                return nil
            },
            NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self, self.panel != nil else { return event }

                // Escape.
                if event.keyCode == 53 {
                    self.dismiss()
                    return nil
                }

                return event
            },
        ].compactMap { $0 }

        observers = [
            Self.observe(NSApplication.didResignActiveNotification) { [weak self] in self?.dismiss() },
            Self.observe(NSWindow.didResignKeyNotification, object: menu) { [weak self] in self?.dismiss() },
        ]
    }

    func dismiss() {
        for monitor in monitors {
            NSEvent.removeMonitor(monitor)
        }

        monitors = []

        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
        }

        observers = []

        if let panel {
            panel.parent?.removeChildWindow(panel)
            panel.orderOut(nil)
            self.panel = nil
        }
    }

    /// `PopupMenu::HelperClasses::MenuWindow::calculateWindowPos` with `alignToRectangle`, in
    /// AppKit's bottom-up screen coordinates: left-aligned with the target, below it unless the
    /// menu fits better above, then kept inside the screen's usable area.
    private static func frame(size: CGSize, target: CGRect, scale: CGFloat) -> CGRect {
        let screen = NSScreen.screens.first { $0.frame.contains(CGPoint(x: target.midX, y: target.midY)) }
            ?? NSScreen.main
        let area = screen?.visibleFrame ?? target

        let spaceUnder = target.minY - area.minY
        let spaceOver = area.maxY - target.maxY
        let buffer = 30 * scale

        let below = size.height < spaceUnder - buffer || spaceUnder >= spaceOver
        var origin = CGPoint(x: target.minX, y: below ? target.minY - size.height : target.maxY)

        origin.x = max(area.minX + scale, min(area.maxX - (size.width + 6 * scale), origin.x))
        origin.y = max(area.minY + 6 * scale, min(area.maxY - scale - size.height, origin.y))

        return CGRect(origin: origin, size: size)
    }

    /// Takes key so the rows get their hover and click without the app changing focus first.
    private final class MenuWindow: NSPanel {
        override var canBecomeKey: Bool { true }

        override var canBecomeMain: Bool { false }
    }

    /// A hosting view that answers the first click in a window that was not key yet.
    private final class KeyHostingView<Content: View>: NSHostingView<Content> {
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    }

    /// A block observer on the default centre, handed back so `dismiss` can remove it.
    private static func observe(_ name: Notification.Name,
                                object: Any? = nil,
                                _ body: @escaping @MainActor () -> Void) -> NSObjectProtocol {
        NotificationCenter.default.addObserver(forName: name, object: object, queue: .main) { _ in
            MainActor.assumeIsolated { body() }
        }
    }
}
