import SwiftUI

/// A batch row's status cell (issue #24 §2): waiting, separating or transcribing with a
/// percentage and a bar, done with the note count, skipped, or failed with the reason.
struct BatchStatusCell: View {
    let state: BatchItem.State

    var body: some View {
        switch state {
        case .waiting:
            Text("Waiting").foregroundStyle(.secondary)
        case .loading:
            Text("Loading…").foregroundStyle(.secondary)
        case let .separating(fraction):
            progress(String(localized: "Separating", comment: "Batch window: a file whose stems are being separated"), fraction)
        case let .transcribing(fraction):
            progress(String(localized: "Transcribing", comment: "Batch window: a file being transcribed"), fraction)
        case .writing:
            Text("Writing…").foregroundStyle(.secondary)
        case let .done(notes, skipped):
            Text(Self.doneText(notes: notes, skipped: skipped))
        case let .failed(reason):
            Label(reason, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
                .lineLimit(1)
                .help(reason)
        }
    }

    private func progress(_ title: String, _ fraction: Double) -> some View {
        HStack(spacing: 8) {
            ProgressView(value: fraction)
                .frame(width: 80)
                .accessibilityHidden(true)
            Text(verbatim: "\(title) \(Int(fraction * 100)) %")
                .monospacedDigit()
        }
    }

    static func doneText(notes: Int?, skipped: Int) -> String {
        guard let notes else {
            return String(localized: "Skipped: already there", comment: "Batch window: every output of a file existed already")
        }

        let count = String(localized: "Done, \(notes) notes", comment: "Batch window: a file transcribed, with its note count")

        return skipped == 0
            ? count
            : String(localized: "\(count) (\(skipped) skipped)", comment: "Batch window: a done file, some of whose outputs existed already")
    }
}
