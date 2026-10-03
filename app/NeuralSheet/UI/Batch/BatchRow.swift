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
            progress("Separating", fraction)
        case let .transcribing(fraction):
            progress("Transcribing", fraction)
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
            Text("\(title) \(Int(fraction * 100)) %")
                .monospacedDigit()
        }
    }

    static func doneText(notes: Int?, skipped: Int) -> String {
        guard let notes else { return "Skipped: already there" }

        let count = notes == 1 ? "Done, 1 note" : "Done, \(notes) notes"

        return skipped == 0 ? count : "\(count) (\(skipped) skipped)"
    }
}
