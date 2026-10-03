import AppKit
import NeuralSheetCore

/// The scroll view's document: the three bands stacked at the content width.
final class TimelineDocumentView: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        clipsToBounds = true
    }

    required init?(coder: NSCoder) {
        nil
    }

    override var isFlipped: Bool { true }
}

/// The drop target for audio and MIDI files: the whole timeline, as `CombinedAudioMidiRegion` was a
/// `FileDragAndDropTarget` for everything inside its viewport (§2.2). Registered on the container
/// rather than on the document, so a file let go over the Load button or the Transcribe
/// call-to-action — which sit over the bands, outside the scroll view — lands too.
extension TimelineContainerView {
    /// Anything but a run in flight or a recording: dropping replaces whatever is loaded.
    private var acceptsDrops: Bool {
        let state = model.state

        return state == .empty || state == .audioLoaded || state == .populated
    }

    /// The viewport's own area: the gutter and the keyboard were never part of the target.
    private func isOverBands(_ sender: NSDraggingInfo) -> Bool {
        scrollView.frame.contains(convert(sender.draggingLocation, from: nil))
    }

    private func droppedURL(_ sender: NSDraggingInfo) -> URL? {
        let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self],
                                                         options: [.urlReadingFileURLsOnly: true]) as? [URL]

        return urls?.first
    }

    private static func isSupported(_ url: URL) -> Bool {
        AudioFileLoader.acceptedExtensions.contains(url.pathExtension.lowercased())
    }

    /// A MIDI file lights the zone only when there is a take to import it over; without one it
    /// is still accepted, so the drop can say why it was refused (MIDI import design §2).
    private func lightsUp(_ url: URL) -> Bool {
        AppModel.isMIDI(url) ? model.canImportMIDI : TimelineContainerView.isSupported(url)
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        draggingUpdated(sender)
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard acceptsDrops, isOverBands(sender), let url = droppedURL(sender) else {
            waveform.isFileOver = false
            return []
        }

        // The zone lights up for a file that can be loaded; an unsupported one is still accepted,
        // so the drop can say why it was refused (`fileDragEnter` / `filesDropped`).
        waveform.isFileOver = lightsUp(url)

        return .copy
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        waveform.isFileOver = false
    }

    override func draggingEnded(_ sender: NSDraggingInfo) {
        waveform.isFileOver = false
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        waveform.isFileOver = false

        guard acceptsDrops, isOverBands(sender), let url = droppedURL(sender) else { return false }

        // MIDI goes over the take rather than replacing it; `importMIDI` refuses without one.
        // `loadAudio` refuses an unsupported extension with the "Could not load the file." message.
        if AppModel.isMIDI(url) {
            model.importMIDI(url: url)
        } else {
            model.loadAudio(url: url)
        }

        return true
    }
}
