import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// The MIDI chip at the trailing end of the Edit and Score toolbars (MIDI out design §2): a
/// document glyph and "MIDI", dragged onto the Finder or a DAW's track as the `.mid` File →
/// Export MIDI… would write, or with ⌥ held at the mouse-down as the `.musicxml`. A click without
/// a drag runs Export MIDI…. Dimmed and inert until there is a finished transcription.
///
/// NeuralNote's drag-out, reduced to a chip with a file promise: the file is written when the
/// receiver asks for it, so the drop carries the tempo and the mix as they are then.
struct MidiDragChip: View {
    let model: AppModel

    @Environment(\.uiScale) private var k

    private typealias Metrics = Toolbar.Metrics

    var body: some View {
        let s = Scaled(k: k)
        let enabled = model.canExport
        let model = model

        HStack(spacing: s(6)) {
            DocumentGlyph()
                .stroke(style: Icons.strokeStyle(scale: k))
                .frame(width: s(Metrics.iconSize), height: s(Metrics.iconSize))

            Text("MIDI")
                .font(Fonts.buttonLabel(k))
                .fixedSize()
        }
        .foregroundStyle(Theme.textButton)
        .padding(.horizontal, s(Metrics.buttonPadX - 2))
        .frame(height: s(Metrics.buttonHeight))
        .background(RoundedRectangle(cornerRadius: s(Metrics.corner), style: .circular).fill(Theme.bgControlAlt))
        .opacity(enabled ? 1 : Theme.disabledAlpha)
        .overlay(
            MidiDragSource(isEnabled: enabled,
                           export: { musicXML in model.dragExport(musicXML: musicXML) },
                           click: { model.requestExport() })
        )
        .tooltip("Drag the MIDI into a DAW or the Finder | ⌥ for MusicXML · click to export")
        // A file promise needs a mouse; to VoiceOver and the keyboard the chip is the click,
        // Export MIDI…, which writes the same file (a11y design §2).
        .accessibleButton(Text(AccessibilityText.exportMIDI), isEnabled: enabled) { model.requestExport() }
    }
}

/// A page with its corner folded: the chip's glyph, in the icons' 16-point design square.
private nonisolated struct DocumentGlyph: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()

        p.move(to: CGPoint(x: 3.5, y: 1.5))
        p.addLine(to: CGPoint(x: 9.5, y: 1.5))
        p.addLine(to: CGPoint(x: 12.5, y: 4.5))
        p.addLine(to: CGPoint(x: 12.5, y: 14.5))
        p.addLine(to: CGPoint(x: 3.5, y: 14.5))
        p.closeSubpath()
        p.move(to: CGPoint(x: 9.5, y: 1.5))
        p.addLine(to: CGPoint(x: 9.5, y: 4.5))
        p.addLine(to: CGPoint(x: 12.5, y: 4.5))

        return IconGeometry.fitted(p, in: rect)
    }
}

/// The chip's mouse: an AppKit view over it, because a file promise needs an `NSDraggingSource`.
private struct MidiDragSource: NSViewRepresentable {
    let isEnabled: Bool
    let export: (Bool) -> (name: String, data: @MainActor () -> Data?)?
    let click: () -> Void

    func makeNSView(context: Context) -> MidiDragSourceView {
        MidiDragSourceView()
    }

    func updateNSView(_ view: MidiDragSourceView, context: Context) {
        view.isEnabled = isEnabled
        view.export = export
        view.click = click
    }
}

/// Starts the drag once the pointer has moved a few points from the mouse-down, and treats a
/// mouse-up without one as a click.
final class MidiDragSourceView: NSView, NSDraggingSource {
    var isEnabled = false
    var export: ((Bool) -> (name: String, data: @MainActor () -> Data?)?)?
    var click: (() -> Void)?

    /// How far the pointer travels before a press becomes a drag, in points.
    private static let dragThreshold: CGFloat = 3

    private var downPoint: CGPoint?
    private var musicXML = false
    private var dragging = false
    private var writer: MidiPromiseWriter?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }

        downPoint = convert(event.locationInWindow, from: nil)
        // At the mouse-down, as the tooltip says: releasing ⌥ mid-drag does not change the file.
        musicXML = event.modifierFlags.contains(.option)
        dragging = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard isEnabled, !dragging, let downPoint else { return }

        let point = convert(event.locationInWindow, from: nil)
        guard hypot(point.x - downPoint.x, point.y - downPoint.y) >= MidiDragSourceView.dragThreshold else { return }

        dragging = true
        startDrag(with: event)
    }

    override func mouseUp(with event: NSEvent) {
        defer { downPoint = nil }

        guard isEnabled, downPoint != nil, !dragging else { return }

        click?()
    }

    private func startDrag(with event: NSEvent) {
        guard let file = export?(musicXML) else { return }

        let type: UTType = musicXML ? UTType(filenameExtension: "musicxml", conformingTo: .xml) ?? .xml : .midi
        let writer = MidiPromiseWriter(fileName: file.name, data: file.data)
        let provider = NSFilePromiseProvider(fileType: type.identifier, delegate: writer)
        // The provider holds the writer for as long as the pasteboard holds the provider: its
        // delegate is weak, and the receiver may ask for the file after the session has ended.
        provider.userInfo = writer
        self.writer = writer

        let item = NSDraggingItem(pasteboardWriter: provider)
        let icon = NSWorkspace.shared.icon(for: type)
        let side = min(bounds.height * 1.6, 48)
        icon.size = NSSize(width: side, height: side)

        let origin = convert(event.locationInWindow, from: nil)
        item.setDraggingFrame(NSRect(x: origin.x - side / 2, y: origin.y - side / 2, width: side, height: side),
                              contents: icon)

        beginDraggingSession(with: [item], event: event, source: self)
    }

    // MARK: - NSDraggingSource

    func draggingSession(_ session: NSDraggingSession,
                         sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        context == .outsideApplication ? .copy : []
    }

    /// The drop is done or abandoned: the drag's scratch folder goes, after any write still
    /// queued for it (MIDI out design §2).
    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        writer?.cleanUp()
        writer = nil
    }
}

/// Writes one promised file (MIDI out design §2): its bytes from the model on the main actor, then
/// into a scratch folder of this drag's own under `temporaryDirectory/NeuralSheet`, copied to where
/// the receiver asked for it, and the scratch folder removed -- all on the provider's queue, which
/// is serial, so ``cleanUp()`` lands after any write already queued.
nonisolated final class MidiPromiseWriter: NSObject, NSFilePromiseProviderDelegate, @unchecked Sendable {
    private let fileName: String
    private let data: @MainActor () -> Data?
    private let folder = AppModel.dragScratchFolder.appendingPathComponent(UUID().uuidString, isDirectory: true)

    private let queue: OperationQueue = {
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        queue.qualityOfService = .userInitiated
        queue.name = "NeuralSheet drag-out"
        return queue
    }()

    init(fileName: String, data: @escaping @MainActor () -> Data?) {
        self.fileName = fileName
        self.data = data
    }

    func filePromiseProvider(_ filePromiseProvider: NSFilePromiseProvider, fileNameForType fileType: String) -> String {
        fileName
    }

    func operationQueue(for filePromiseProvider: NSFilePromiseProvider) -> OperationQueue {
        queue
    }

    func filePromiseProvider(_ filePromiseProvider: NSFilePromiseProvider, writePromiseTo url: URL,
                             completionHandler: @escaping (Error?) -> Void) {
        let completion = UncheckedBox(completionHandler)

        // The model is the main actor's: its bytes are made there, at drop time, with the same
        // writer the export menu uses; the file is written back on this queue.
        DispatchQueue.main.async { [self] in
            let bytes = MainActor.assumeIsolated { data() }

            queue.addOperation { [self] in
                completion.value(write(bytes, to: url))
            }
        }
    }

    /// Removes this drag's scratch folder, behind any write already on the queue.
    func cleanUp() {
        let folder = folder

        queue.addOperation {
            try? FileManager.default.removeItem(at: folder)
        }
    }

    private func write(_ bytes: Data?, to url: URL) -> Error? {
        guard let bytes else { return CocoaError(.fileWriteUnknown) }

        let scratch = folder.appendingPathComponent(fileName)
        defer { try? FileManager.default.removeItem(at: folder) }

        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try bytes.write(to: scratch, options: .atomic)

            try FileManager.default.copyItem(at: scratch, to: url)

            return nil
        } catch {
            return error
        }
    }
}

/// Carries a non-`Sendable` completion handler across the hop to the main queue and back; it is
/// called exactly once, on the provider's queue.
private nonisolated struct UncheckedBox<Value>: @unchecked Sendable {
    let value: Value

    init(_ value: Value) {
        self.value = value
    }
}
