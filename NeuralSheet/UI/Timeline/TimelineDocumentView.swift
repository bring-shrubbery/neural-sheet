import AppKit
import NeuralSheetCore

/// The scroll view's document: the three bands, and the drop target for audio files
/// (`CombinedAudioMidiRegion` as a `FileDragAndDropTarget`).
final class TimelineDocumentView: NSView {
    weak var container: TimelineContainerView?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        clipsToBounds = true
        registerForDraggedTypes([.fileURL])
    }

    required init?(coder: NSCoder) {
        nil
    }

    override var isFlipped: Bool { true }

    // MARK: - Drops

    /// Anything but a run in flight or a recording: dropping replaces whatever is loaded (§2.2).
    private var acceptsDrops: Bool {
        guard let state = container?.model.state else { return false }

        return state == .empty || state == .audioLoaded || state == .populated
    }

    private func droppedURL(_ sender: NSDraggingInfo) -> URL? {
        let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self],
                                                         options: [.urlReadingFileURLsOnly: true]) as? [URL]

        return urls?.first
    }

    private static func isSupported(_ url: URL) -> Bool {
        AudioFileLoader.acceptedExtensions.contains(url.pathExtension.lowercased())
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard acceptsDrops, let url = droppedURL(sender) else { return [] }

        // The zone lights up for a file that can be loaded; an unsupported one is still accepted,
        // so the drop can say why it was refused.
        container?.waveform.isFileOver = TimelineDocumentView.isSupported(url)

        return .copy
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        container?.waveform.isFileOver = false
    }

    override func draggingEnded(_ sender: NSDraggingInfo) {
        container?.waveform.isFileOver = false
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        container?.waveform.isFileOver = false

        guard acceptsDrops, let url = droppedURL(sender), let container else { return false }

        // `loadAudio` refuses an unsupported extension with the "Could not load the file." message.
        container.model.loadAudio(url: url)

        return true
    }
}
