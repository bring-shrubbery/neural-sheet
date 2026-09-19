import NeuralSheetCore
import SwiftUI

/// The strip along the bottom of the window (`StatusBar`): the transcription's figures on the
/// left, the vertical-zoom control on the right, and the progress group beside it while a run is
/// in flight.
///
/// The figures are drawn under the controls rather than beside them, as the original's label was:
/// they grow with the transcription, and the controls own the right-hand end regardless.
struct StatusBar: View {
    let model: AppModel

    /// What the slider shows while the zoom is automatic (`verticalZoom < 0`): the norm that fits
    /// the transcription, which the timeline computes from its own height (Task 19). Until it is
    /// passed in, automatic reads as fully zoomed out.
    var automaticNorm: Double = 0

    @Environment(\.uiScale) private var k

    /// `StatusBar.cpp` and `nn::metrics`, authored at 1x.
    enum Metrics {
        static let height: CGFloat = 26
        static let paddingSide: CGFloat = 14
        static let segmentGap: CGFloat = 14
        static let zoomIconSize: CGFloat = 11
        static let zoomTrackWidth: CGFloat = 74
        static let zoomGap: CGFloat = 8
        static let progressGapToZoom: CGFloat = 24
    }

    static let separator = "\u{00B7}"

    var body: some View {
        let s = Scaled(k: k)

        VStack(spacing: 0) {
            Rectangle()
                .fill(Theme.divSoft)
                .frame(height: k)

            ZStack {
                segmentsRow
                    .frame(maxWidth: .infinity, alignment: .leading)

                controlsRow
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .padding(.horizontal, s(Metrics.paddingSide))
            .frame(maxHeight: .infinity)
        }
        .frame(height: s(Metrics.height))
        .frame(maxWidth: .infinity)
        .background(Theme.bgPanel)
    }

    // MARK: - Figures

    /// `"<n> instrument(s)"`, `"<n> notes"`, then the pitch range and the duration, each only once
    /// it means something: an instrument can be selected before it has been transcribed, and its
    /// empty range would otherwise read as "C-1 - C-1".
    var segments: [String] {
        let status = model.statusLine

        var segments = [
            "\(status.instruments) " + (status.instruments == 1 ? "instrument" : "instruments"),
            "\(status.notes) notes",
        ]

        if status.notes > 0, let lowest = status.lowest, let highest = status.highest {
            segments.append("\(TimeFormat.pitchName(lowest)) - \(TimeFormat.pitchName(highest))")
        }

        if model.duration > 0 {
            segments.append("\(TimeFormat.seconds2(model.duration)) s")
        }

        return segments
    }

    private var segmentsRow: some View {
        let s = Scaled(k: k)

        return HStack(spacing: s(Metrics.segmentGap)) {
            ForEach(Array(segments.enumerated()), id: \.offset) { index, segment in
                if index > 0 {
                    Text(Self.separator)
                        .foregroundStyle(Theme.textSeparator)
                }

                Text(segment)
                    .foregroundStyle(Theme.textFainter)
            }
        }
        .font(Fonts.statusBar(k))
        .lineLimit(1)
        .fixedSize()
    }

    // MARK: - Controls

    private var controlsRow: some View {
        let s = Scaled(k: k)

        return HStack(spacing: 0) {
            if model.state == .processing {
                TranscriptionProgress(model: model)

                Spacer().frame(width: s(Metrics.progressGapToZoom))
            }

            Icons.VerticalZoomStroked()
                .stroke(Theme.zoomIcon, style: Icons.strokeStyle(scale: k))
                .frame(width: s(Metrics.zoomIconSize), height: s(Metrics.zoomIconSize))

            Spacer().frame(width: s(Metrics.zoomGap))

            PillSlider(value: zoom,
                       range: 0 ... 1,
                       width: s(Metrics.zoomTrackWidth),
                       fill: Theme.zoomFill,
                       track: Theme.zoomTrack,
                       thumb: Theme.zoomThumb)
                .tooltip("Piano roll vertical zoom")
                .accessibilityLabel("Piano roll vertical zoom")
        }
    }

    /// The slider reads the zoom, or the fit while it is automatic; moving it takes the zoom off
    /// automatic (§7.2).
    private var zoom: Binding<Double> {
        Binding(
            get: { model.verticalZoom < 0 ? automaticNorm : model.verticalZoom },
            set: { model.verticalZoom = $0 })
    }
}
