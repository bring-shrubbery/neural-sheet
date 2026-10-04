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
/// ("Transcribing", "Paused — cooling down"), and the percentage. VoiceOver reads each
/// presentation as one element: the name, the status and the percentage (sub-issue J).
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

                    Text(Self.fraction(context), format: .percent)
                        .font(.title2.monospacedDigit())
                }

                ProgressView(value: Double(context.state.percent), total: 100)
            }
            .padding()
            .activityBackgroundTint(Color.black.opacity(0.6))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Self.spoken(context))
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Image(systemName: "waveform")
                        .accessibilityHidden(true)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Text(Self.fraction(context), format: .percent)
                        .monospacedDigit()
                        .accessibilityHidden(true)
                }
                DynamicIslandExpandedRegion(.center) {
                    Text(context.attributes.fileName)
                        .lineLimit(1)
                        .accessibilityLabel(Self.spoken(context))
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(spacing: 4) {
                        ProgressView(value: Double(context.state.percent), total: 100)
                        Text(context.state.status)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .accessibilityHidden(true)
                }
            } compactLeading: {
                Image(systemName: "waveform")
                    .accessibilityLabel(Text(context.attributes.fileName))
            } compactTrailing: {
                Text(Self.fraction(context), format: .percent)
                    .monospacedDigit()
                    .accessibilityLabel(Text(verbatim: "\(context.state.status), \(Self.percentText(context))"))
            } minimal: {
                Text(verbatim: "\(context.state.percent)")
                    .monospacedDigit()
                    .accessibilityLabel(Self.spoken(context))
            }
        }
    }

    /// 0…1, for the locale's percent format: "42%", "42 %".
    private static func fraction(_ context: ActivityViewContext<TranscriptionActivityAttributes>) -> Double {
        Double(context.state.percent) / 100
    }

    private static func percentText(_ context: ActivityViewContext<TranscriptionActivityAttributes>) -> String {
        fraction(context).formatted(.percent)
    }

    /// "take.wav, Transcribing, 42%".
    private static func spoken(_ context: ActivityViewContext<TranscriptionActivityAttributes>) -> Text {
        Text("\(context.attributes.fileName), \(context.state.status), \(percentText(context))",
             comment: "VoiceOver (Live Activity): the take's name, what the run is doing and how far it is, e.g. \"take.wav, Transcribing, 42%\"")
    }
}
