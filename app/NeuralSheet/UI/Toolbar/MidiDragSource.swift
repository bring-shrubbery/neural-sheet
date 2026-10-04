import AppKit
import SwiftUI
import UniformTypeIdentifiers

// The MIDI chip's drag (MIDI out design §2), apart from the chip so the Audio Unit's view drags
// the same file promise (Audio Unit design §2, "UI"; it compiles this file by path).

/// The chip's mouse: an AppKit view over it, because a file promise needs an `NSDraggingSource`.
struct MidiDragSource: NSViewRepresentable {
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
    private let folder = MidiPromiseWriter.scratchFolder.appendingPathComponent(UUID().uuidString, isDirectory: true)

    /// `temporaryDirectory/NeuralSheet`: each drag writes into a folder of its own here, removed
    /// once the drop is done (issue #21 requirement 9).
    static var scratchFolder: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("NeuralSheet", isDirectory: true)
    }

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
