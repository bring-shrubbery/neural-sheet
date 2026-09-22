import NeuralSheetCore
import SwiftUI

/// "ORIG" ... slider ... "MIDI": the crossfade between the source audio and the synth, in the
/// sidebar's master panel (the inventory's top bar had it; ours sits beside the level it feeds).
/// Dimmed rather than disabled while there are no notes to balance against: what it sets
/// survives a take being cleared.
///
/// Either label held down solos its side for as long as the mouse is down; the slider follows
/// the hold and comes back to the set value on release. Under the stereo split the slider is
/// inert and dimmed -- both sides play at full -- but the holds still work, each silencing the
/// other ear.
struct MixPill: View {
    let model: AppModel
    /// The slider's track in authored points.
    let trackWidth: CGFloat
    let height: CGFloat
    let corner: CGFloat

    @Environment(\.uiScale) private var k

    private static let padding: CGFloat = 12
    private static let gap: CGFloat = 9

    var body: some View {
        let s = Scaled(k: k)
        let alpha = model.notes.isEmpty ? Theme.disabledAlpha : 1.0
        let split = model.stereoSplit
        // Reads what is playing, writes the setting: a drag while a label is held moves the set
        // value underneath, which is what shows once the hold ends.
        let mix = Binding(get: { model.effectiveMix }, set: { model.mix = $0 })

        HStack(spacing: s(Self.gap)) {
            MixHoldLabel(text: "ORIG",
                         colour: Theme.textMuted,
                         isHeld: model.mixHold == 0,
                         begin: { model.beginMixHold(.source) },
                         end: model.endMixHold)
                .tooltip(split ? "Hold to hear only the source audio, in the left ear" : "Hold to hear only the source audio")

            PillSlider(value: mix,
                       range: 0 ... 1,
                       step: 0.001,
                       width: s(trackWidth),
                       fill: Theme.accent.opacity(0.8),
                       track: Theme.faderTrackTop,
                       thumb: Theme.faderThumb)
                .disabled(split)
                .opacity(split ? Theme.disabledAlpha : 1)
                .tooltip(split
                    ? "Nothing to balance while the split is on: each side plays at full in its own ear"
                    : "Balance between the source audio and the synthesised transcription | [ ]")

            MixHoldLabel(text: "MIDI",
                         colour: Theme.accentText,
                         isHeld: model.mixHold == 1,
                         begin: { model.beginMixHold(.synth) },
                         end: model.endMixHold)
                .tooltip(split ? "Hold to hear only the MIDI, in the right ear" : "Hold to hear only the MIDI")
        }
        .padding(.horizontal, s(Self.padding))
        .frame(height: s(height))
        .background(RoundedRectangle(cornerRadius: s(corner), style: .circular).fill(Theme.bgControl))
        .opacity(alpha)
    }
}

/// A pill's caption, boxed at the tracked width `nn::trackedTextWidth` gave it.
private struct PillLabelText: View {
    let text: String
    let colour: Color

    @Environment(\.uiScale) private var k

    var body: some View {
        let s = Scaled(k: k)
        let width = TrackedText.width(text,
                                      fontName: Fonts.sansName(500),
                                      pointSize: Fonts.Size.pillLabel,
                                      trackingEm: Fonts.Tracking.pillLabel).rounded(.up)

        return Text(text)
            .font(Fonts.pillLabel(k))
            .kerning(Fonts.tracking(Fonts.Tracking.pillLabel, pointSize: Fonts.Size.pillLabel, scale: k))
            .foregroundStyle(colour)
            .fixedSize()
            .frame(width: s(width), alignment: .leading)
    }
}

/// ORIG or MIDI as a momentary button: the hold starts on mouse-down and ends on release, wherever
/// the pointer went (a zero-distance drag, as `FlatButton` presses). Bright while held, so the
/// solo reads on the label as well as on the slider.
private struct MixHoldLabel: View {
    let text: String
    let colour: Color
    let isHeld: Bool
    let begin: () -> Void
    let end: () -> Void

    @Environment(\.uiScale) private var k
    @State private var isPressed = false

    var body: some View {
        let s = Scaled(k: k)

        PillLabelText(text: text, colour: isHeld ? Theme.textBright : colour)
            // A little more than the glyphs, so the target is not the letter strokes alone.
            .padding(.vertical, s(8))
            .padding(.horizontal, s(3))
            .contentShape(Rectangle())
            .padding(.horizontal, -s(3))
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in
                        if !isPressed {
                            isPressed = true
                            begin()
                        }
                    }
                    .onEnded { _ in
                        isPressed = false
                        end()
                    })
            .pointerStyle(.link)
            .accessibilityAddTraits(.isButton)
            .accessibilityLabel("\(text): hold to hear only this side")
    }
}
