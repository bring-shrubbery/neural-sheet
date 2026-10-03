import ActivityKit
import SwiftUI
import WidgetKit

/// The app's widget extension: for now only the transcription's Live Activity (iOS app design §2,
/// Background).
@main
struct NeuralSheetWidgets: WidgetBundle {
    var body: some Widget {
        TranscriptionLiveActivity()
    }
}

/// A run on the Lock Screen and in the Dynamic Island: the take's name, what the run is doing
/// ("Transcribing", "Paused — cooling down"), and the percentage.
struct TranscriptionLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: TranscriptionActivityAttributes.self) { context in
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 10) {
                    Image(systemName: "waveform")
                        .font(.title3)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(context.attributes.fileName)
                            .font(.headline)
                            .lineLimit(1)
                        Text(context.state.status)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    Text(verbatim: "\(context.state.percent)%")
                        .font(.title2.monospacedDigit())
                }

                ProgressView(value: Double(context.state.percent), total: 100)
            }
            .padding()
            .activityBackgroundTint(Color.black.opacity(0.6))
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Image(systemName: "waveform")
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Text(verbatim: "\(context.state.percent)%")
                        .monospacedDigit()
                }
                DynamicIslandExpandedRegion(.center) {
                    Text(context.attributes.fileName)
                        .lineLimit(1)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(spacing: 4) {
                        ProgressView(value: Double(context.state.percent), total: 100)
                        Text(context.state.status)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            } compactLeading: {
                Image(systemName: "waveform")
            } compactTrailing: {
                Text(verbatim: "\(context.state.percent)%")
                    .monospacedDigit()
            } minimal: {
                Text(verbatim: "\(context.state.percent)")
                    .monospacedDigit()
            }
        }
    }
}
