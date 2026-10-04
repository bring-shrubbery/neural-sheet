import Foundation
import NeuralSheetCore

/// File → Export Audio…'s choices, what they ask the offline render for, and the render into a
/// file (audio export design §2), shared by both models. The questions are asked by each
/// platform's own panel or sheet; the render runs off the main actor.
nonisolated extension ExportCommands {
    /// What / Range / Format, as the panel's accessory edits them and the settings remember them.
    struct AudioChoice: Equatable, Sendable {
        var what: AudioExportWhat
        var markedRange: Bool
        var format: AudioExportFormat

        /// The remembered choice as the panel opens with it: *Original only* without a finished
        /// transcription, the whole take without a marked range.
        func starting(hasRange: Bool, hasNotes: Bool) -> AudioChoice {
            var start = self
            if !hasNotes { start.what = .original }
            if !hasRange { start.markedRange = false }
            return start
        }
    }

    /// The render the choice asks for: the marked range when chosen and there is one, the whole
    /// take otherwise.
    static func renderSpec(_ choice: AudioChoice, marked: Range<Double>?, duration: Double) -> RenderSpec {
        let whole = 0 ... max(duration, 0)
        let range = choice.markedRange ? marked.map { $0.lowerBound ... $0.upperBound } ?? whole : whole

        return RenderSpec(what: choice.what, range: range, format: choice.format)
    }

    /// Off the main actor: renders into a scratch folder on the destination's volume and moves the
    /// file over the destination once whole. Nil on success or cancel.
    static func renderAudio(_ job: OfflineRenderer.Job, to destination: URL,
                            progress: @escaping @Sendable (Double) -> Void) -> Error? {
        let manager = FileManager.default

        do {
            let scratchFolder = try manager.url(for: .itemReplacementDirectory, in: .userDomainMask,
                                                appropriateFor: destination, create: true)
            defer { try? manager.removeItem(at: scratchFolder) }

            let scratch = scratchFolder.appendingPathComponent(destination.lastPathComponent)

            // A hop per percent, not per block.
            var reported = -1
            let finished = try OfflineRenderer.render(job, to: scratch, progress: { fraction in
                let percent = Int(fraction * 100)
                if percent != reported {
                    reported = percent
                    progress(fraction)
                }
            })

            guard finished, !Task.isCancelled else { return nil }

            if manager.fileExists(atPath: destination.path) {
                _ = try manager.replaceItemAt(destination, withItemAt: scratch)
            } else {
                try manager.moveItem(at: scratch, to: destination)
            }

            return nil
        } catch {
            return Task.isCancelled ? nil : error
        }
    }
}
