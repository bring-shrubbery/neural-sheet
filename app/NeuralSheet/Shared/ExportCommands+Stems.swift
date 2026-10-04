import Foundation
import NeuralSheetCore

/// File → Export Stems…'s files (audio export design §2), shared by both models: whether a kept
/// separation is whole, what each stem is named, and the conversion of the kept `.caf` files to
/// 24-bit WAV at the take's rate and channel count.
nonisolated extension ExportCommands {
    /// Every stem the separation keeps is in `folder`.
    static func hasAllStems(in folder: URL) -> Bool {
        (0..<StemNames.displayNames.count).allSatisfy {
            FileManager.default.fileExists(atPath: folder.appendingPathComponent(StemNames.cacheFileName(stem: $0)).path)
        }
    }

    /// The kept file and the file it becomes, in the export's order: `<take name> - Drums.wav` ….
    static func stemPlan(kept: URL, destination: URL, takeName: String) -> [(source: URL, destination: URL)] {
        StemNames.exportOrder.map { stem in
            (kept.appendingPathComponent(StemNames.cacheFileName(stem: stem)),
             destination.appendingPathComponent(StemNames.exportFileName(takeName: takeName, stem: stem)))
        }
    }

    /// Off the main actor: each stem through ``StemFiles/convert(_:to:sampleRate:channels:frameCount:)``
    /// into a scratch file on the destination's volume, moved over the target only once whole, so
    /// a failure or a cancel never leaves a half-written file or loses the one it was replacing.
    /// A cancel removes the files this export already wrote.
    static func convertStems(_ plan: [(source: URL, destination: URL)], sampleRate: Double,
                             channels: Int, frameCount: Int,
                             progress: @escaping @Sendable (Float) -> Void) -> Error? {
        let manager = FileManager.default
        var written: [URL] = []

        for (index, step) in plan.enumerated() {
            guard !Task.isCancelled else { break }

            do {
                let scratchFolder = try manager.url(for: .itemReplacementDirectory, in: .userDomainMask,
                                                    appropriateFor: step.destination, create: true)
                defer { try? manager.removeItem(at: scratchFolder) }

                let scratch = scratchFolder.appendingPathComponent(step.destination.lastPathComponent)

                try StemFiles.convert(step.source, to: scratch, sampleRate: sampleRate, channels: channels,
                                      frameCount: frameCount)

                guard !Task.isCancelled else { break }

                if manager.fileExists(atPath: step.destination.path) {
                    _ = try manager.replaceItemAt(step.destination, withItemAt: scratch)
                } else {
                    try manager.moveItem(at: scratch, to: step.destination)
                }

                written.append(step.destination)
                progress(Float(index + 1) / Float(plan.count))
            } catch {
                return Task.isCancelled ? nil : error
            }
        }

        if Task.isCancelled {
            for url in written { try? manager.removeItem(at: url) }
        }

        return nil
    }
}
