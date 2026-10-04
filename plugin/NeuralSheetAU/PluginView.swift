import SwiftUI

/// The plugin's window in the host. In sub-issue A only the name, the version and the rate the
/// host runs it at; the roll, the transport and the capture come in the later sub-issues.
struct PluginView: View {
    let model: PluginViewModel

    var body: some View {
        VStack(spacing: 8) {
            Text("NeuralSheet")
                .font(.largeTitle.weight(.semibold))
            Text("Version \(model.version)")
                .foregroundStyle(.secondary)
            Text(rateText)
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.background)
    }

    private var rateText: String {
        guard let rate = model.sampleRate else { return "Sample rate: —" }
        return "Sample rate: \(rate.formatted(.number.precision(.fractionLength(0)))) Hz"
    }
}
