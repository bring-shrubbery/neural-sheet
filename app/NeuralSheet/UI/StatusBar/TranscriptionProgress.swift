import SwiftUI

/// A pulsing caption, a 150 x 3 bar, the percentage and a cancel cross: the status bar's
/// transcription progress (`TranscriptionProgress`) and the Edit toolbar's region progress
/// (`RegionProgress`) are this with different words and a different cancel.
///
/// The caption pulses because it says the same thing throughout -- what it is for is to say that
/// something is still happening between two percentage ticks, which can be seconds apart. Once the
/// cross has been pressed the group dims rather than relabelling: the run is still going until the
/// engine reaches a chunk boundary, and saying otherwise would be a lie for as long as that takes.
struct ProgressGroup: View {
    let caption: String
    /// 0…1.
    let progress: Float
    let cancelling: Bool
    let cancelTooltip: String
    let onCancel: () -> Void

    @Environment(\.uiScale) private var k

    /// `nn::metrics` and `TranscriptionProgress.cpp`, authored at 1x.
    enum Metrics {
        static let barWidth: CGFloat = 150
        static let barHeight: CGFloat = 3
        static let barCorner: CGFloat = 2
        static let percentWidth: CGFloat = 28
        static let cancelHitSize: CGFloat = 16
        static let cancelGlyphSize: CGFloat = 9
        static let cancelCorner: CGFloat = 4
        static let gap: CGFloat = 10
        static let captionTracking: Double = 0.06
    }

    /// One breath in and out.
    static let pulsePeriod: TimeInterval = 1.6
    static let pulseMin: Double = 0.55

    /// The caption's alpha at a moment: a raised cosine between `pulseMin` and 1 over
    /// `pulsePeriod`, rounded to a hundredth so a pulse that has barely moved does not repaint.
    static func pulse(at seconds: TimeInterval) -> Double {
        let phase = seconds.truncatingRemainder(dividingBy: pulsePeriod) / pulsePeriod
        let eased = 0.5 - 0.5 * cos(phase * 2 * .pi)

        return ((pulseMin + (1 - pulseMin) * eased) * 100).rounded() / 100
    }

    var body: some View {
        let s = Scaled(k: k)
        let percent = Int((100 * progress).rounded())
        let dim = cancelling ? Theme.disabledAlpha : 1

        HStack(spacing: s(Metrics.gap)) {
            SwiftUI.TimelineView(.animation(paused: cancelling)) { context in
                // The alpha is the only thing that changes per frame, and it changes at most a
                // hundredth at a time, so the text is not re-laid-out for a pulse that stood still.
                captionLabel
                    .opacity(cancelling
                        ? Theme.disabledAlpha
                        : Self.pulse(at: context.date.timeIntervalSinceReferenceDate))
            }

            bar(percent: percent, dim: dim)

            Text("\(percent)%")
                .font(Fonts.statusBar(k))
                .foregroundStyle(Theme.progressText)
                .opacity(dim)
                .lineLimit(1)
                .fixedSize()
                .frame(width: s(Metrics.percentWidth), alignment: .trailing)

            cancelButton
        }
        .fixedSize()
    }

    private var captionLabel: some View {
        TrackedLabel(string: caption,
                    em: Metrics.captionTracking,
                    pointSize: Fonts.Size.statusBar,
                    font: Fonts.statusBar(k),
                    scale: k)
            .foregroundStyle(Theme.progressText)
            .fixedSize()
    }

    private func bar(percent: Int, dim: Double) -> some View {
        let s = Scaled(k: k)
        let shape = RoundedRectangle(cornerRadius: s(Metrics.barCorner), style: .circular)
        let filled = s(Metrics.barWidth) * CGFloat(percent) / 100

        return ZStack(alignment: .leading) {
            shape.fill(Theme.progressTrack)

            if filled > 0 {
                shape.fill(Theme.progressFill)
                    .frame(width: max(filled, 2 * s(Metrics.barCorner)))
                    .opacity(dim)
            }
        }
        .frame(width: s(Metrics.barWidth), height: s(Metrics.barHeight))
    }

    /// Not disabled once cancelling: cancelling is idempotent, and a button that stops responding
    /// to the second click is a button the user has to assume is broken.
    private var cancelButton: some View {
        let s = Scaled(k: k)

        return FlatButton(idle: .clear,
                          on: Theme.bgControlActive,
                          corner: s(Metrics.cancelCorner),
                          action: onCancel) { _ in
            Icons.CrossStroked()
                .stroke(style: Icons.strokeStyle(scale: k))
                .frame(width: s(Metrics.cancelGlyphSize), height: s(Metrics.cancelGlyphSize))
                .frame(width: s(Metrics.cancelHitSize), height: s(Metrics.cancelHitSize))
        }
        .tooltip(cancelTooltip)
        .accessibilityLabel(cancelTooltip)
    }
}

/// The status bar's progress group while a run is in flight (`TranscriptionProgress`).
struct TranscriptionProgress: View {
    let model: AppModel

    static let caption = "TRANSCRIBING"

    var body: some View {
        ProgressGroup(caption: Self.caption,
                      progress: model.transcriptionProgress,
                      cancelling: model.cancelLatched,
                      cancelTooltip: "Cancel transcription",
                      onCancel: model.cancelTranscription)
    }
}
