import AppKit
import NeuralSheetCore
import SwiftUI
import UniformTypeIdentifiers

/// File → Export Audio…'s save panel (audio export design §2): titled "Export Audio", in the Music
/// folder like the other exports, named `"<take name>.wav"`, with a SwiftUI accessory for *What*,
/// *Range* and *Format*. Changing the format changes the name's extension and the type the panel
/// allows. Synchronous, like the other exports' panels: it returns the choice and the URL, or nil.
@MainActor enum ExportAudioPanel {
    struct Choice: Equatable {
        var what: AudioExportWhat
        var markedRange: Bool
        var format: AudioExportFormat
    }

    /// - Parameters:
    ///   - hasRange: A range is marked; otherwise *Marked range* is offered but disabled.
    ///   - hasNotes: There is a finished transcription; otherwise only *Original only* can be
    ///     chosen.
    static func run(takeName: String, directory: URL, initial: Choice, hasRange: Bool,
                    hasNotes: Bool) -> (Choice, URL)? {
        var start = initial
        if !hasNotes { start.what = .original }
        if !hasRange { start.markedRange = false }

        let options = ExportAudioOptions(choice: start, hasRange: hasRange, hasNotes: hasNotes)
        let panel = NSSavePanel()
        panel.title = "Export Audio"
        panel.message = "Export Audio"
        panel.directoryURL = directory
        panel.nameFieldStringValue = start.format.fileName(takeName: takeName)
        panel.allowedContentTypes = [contentType(start.format)]
        panel.canCreateDirectories = true

        options.onFormatChange = { [weak panel] format in
            guard let panel else { return }

            let base = (panel.nameFieldStringValue as NSString).deletingPathExtension
            panel.allowedContentTypes = [contentType(format)]
            panel.nameFieldStringValue = "\(base.isEmpty ? takeName : base).\(format.fileExtension)"
        }

        let host = NSHostingView(rootView: ExportAudioAccessory(options: options))
        host.setFrameSize(host.fittingSize)
        panel.accessoryView = host

        guard panel.runModal() == .OK, let url = panel.url else { return nil }

        return (options.choice, url)
    }

    static func contentType(_ format: AudioExportFormat) -> UTType {
        switch format {
        case .wav24: .wav
        case .aiff24: .aiff
        case .m4a: .mpeg4Audio
        }
    }
}

/// The accessory's state: the choice it edits and what it may offer.
@MainActor @Observable final class ExportAudioOptions {
    var choice: ExportAudioPanel.Choice {
        didSet {
            if choice.format != oldValue.format { onFormatChange?(choice.format) }
        }
    }

    let hasRange: Bool
    let hasNotes: Bool

    @ObservationIgnored var onFormatChange: ((AudioExportFormat) -> Void)?

    init(choice: ExportAudioPanel.Choice, hasRange: Bool, hasNotes: Bool) {
        self.choice = choice
        self.hasRange = hasRange
        self.hasNotes = hasNotes
    }
}

/// What / Range / Format, on system controls like the Settings window.
struct ExportAudioAccessory: View {
    @Bindable var options: ExportAudioOptions

    var body: some View {
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 8, verticalSpacing: 10) {
            GridRow {
                Text("What:").gridColumnAlignment(.trailing)

                Picker("What", selection: $options.choice.what) {
                    ForEach(AudioExportWhat.allCases, id: \.self) { what in
                        Text(what.title)
                            .tag(what)
                            .selectionDisabled(what.includesSynth && !options.hasNotes)
                    }
                }
                .labelsHidden()
                .fixedSize()
            }

            GridRow {
                Text("Range:")

                Picker("Range", selection: $options.choice.markedRange) {
                    Text("Whole take").tag(false)
                    Text("Marked range").tag(true).selectionDisabled(!options.hasRange)
                }
                .pickerStyle(.radioGroup)
                .horizontalRadioGroupLayout()
                .labelsHidden()
            }

            GridRow {
                Text("Format:")

                Picker("Format", selection: $options.choice.format) {
                    ForEach(AudioExportFormat.allCases, id: \.self) { format in
                        Text(format.title).tag(format)
                    }
                }
                .labelsHidden()
                .fixedSize()
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }
}
