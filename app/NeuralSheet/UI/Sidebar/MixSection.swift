import NeuralSheetCore
import SwiftUI

/// The mix at the bottom of the sidebar (native chrome design §4), what the master panel held:
/// the master meter, the crossfade between the source audio and the synth with its holds, the
/// stereo split, the output level with the input mute, and the click with its level (click
/// design §2).
struct MixSection: View {
    @Bindable private var model: AppModel

    init(model: AppModel) {
        _model = Bindable(wrappedValue: model)
    }

    private static let width = SidebarMetrics.width - 2 * (SidebarMetrics.margin + 6)
    private static let valueWidth: CGFloat = 38

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Mix")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(Theme.textLabel)
                    .accessibilityAddTraits(.isHeader)

                Spacer(minLength: 0)
            }

            LevelMeter(db: model.masterLevelDb, segments: 30, gap: 2, height: 4, unlit: Theme.meterUnlitMaster)

            crossfade

            Toggle(isOn: $model.stereoSplit) {
                Text("Stereo split")
            }
            .toggleStyle(.switch)
            .controlSize(.mini)
            .disabled(model.notes.isEmpty)
            .tooltip("Split: the source audio in the left ear, the MIDI in the right, nothing mixed")

            output

            click
        }
        .font(.system(size: 12))
        .frame(width: Self.width, alignment: .leading)
    }

    // MARK: - Crossfade

    /// Original … MIDI. Dimmed rather than disabled while there are no notes to balance against:
    /// what it sets survives a take being cleared. Either label held down solos its side for as
    /// long as the mouse is down; the slider follows the hold and comes back to the set value on
    /// release. Under the stereo split the slider is inert -- both sides play at full -- but the
    /// holds still work, each silencing the other ear.
    private var crossfade: some View {
        let split = model.stereoSplit
        // Reads what is playing, writes the setting: a drag while a label is held moves the set
        // value underneath, which is what shows once the hold ends.
        let mix = Binding(get: { model.effectiveMix }, set: { model.mix = $0 })

        return VStack(spacing: 4) {
            HStack {
                MixHoldLabel(text: String(localized: "Original", comment: "Sidebar: the mix slider's source-audio end; held, only the source plays"),
                             colour: Theme.textMuted,
                             isHeld: model.mixHold == 0,
                             begin: { model.beginMixHold(.source) },
                             end: model.endMixHold)
                    .tooltip(split ? "Hold to hear only the source audio, in the left ear" : "Hold to hear only the source audio")

                Spacer(minLength: 0)

                MixHoldLabel(text: String(localized: "MIDI", comment: "Master panel: the mix slider's MIDI end; held, only the MIDI plays"),
                             colour: Theme.accentText,
                             isHeld: model.mixHold == 1,
                             begin: { model.beginMixHold(.synth) },
                             end: model.endMixHold)
                    .tooltip(split ? "Hold to hear only the MIDI, in the right ear" : "Hold to hear only the MIDI")
            }

            PillSlider(value: mix,
                       range: 0 ... 1,
                       step: 0.001,
                       width: Self.width,
                       fill: Theme.accent.opacity(0.8),
                       track: Theme.faderTrackTop,
                       thumb: Theme.faderThumb,
                       valueText: String(localized: AccessibilityText.mixValue(model.effectiveMix)))
                .accessibilityLabel(Text(AccessibilityText.mix))
                .disabled(split)
                .tooltip(split
                    ? "Nothing to balance while the split is on: each side plays at full in its own ear"
                    : "Balance between the source audio and the synthesised transcription | [ ]")
        }
        .opacity(model.notes.isEmpty ? Theme.disabledAlpha : 1)
    }

    // MARK: - Output

    /// The output level, dimmed until there is something to hear, and the input mute beside it.
    private var output: some View {
        let muted = model.inputMuted

        return HStack(spacing: 8) {
            Button { model.inputMuted.toggle() } label: {
                Image(systemName: muted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(muted ? Theme.warn : Theme.textIcon)
                    .frame(width: 24, height: 24)
                    .background(Circle().fill(muted ? Theme.warn.opacity(0.18) : Theme.bgControl))
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .tooltip("Mute / Unmute input | m")
            .accessibilityLabel(Text(AccessibilityText.muteInput))
            .accessibilityValue(Text(AccessibilityText.onOff(muted)))

            PillSlider(value: $model.masterGainDb,
                       range: InstrumentMixerState.minGainDb ... InstrumentMixerState.maxGainDb,
                       step: 0.1,
                       width: Self.width - 24 - Self.valueWidth - 16,
                       fill: Theme.volumeFill,
                       track: Theme.faderTrackTop,
                       thumb: Theme.faderThumb,
                       valueText: String(localized: AccessibilityText.decibels(model.masterGainDb)))
                .tooltip("Output level")
                .accessibilityLabel(Text(AccessibilityText.outputLevel))
                .opacity(model.state.canPlay ? 1 : Theme.disabledAlpha)

            readout(model.masterGainDb)
        }
    }

    // MARK: - Click

    /// The metronome on the grid's beats, and its level, dimmed while it is off.
    private var click: some View {
        HStack(spacing: 8) {
            Toggle(isOn: Binding(get: { model.clickEnabled }, set: { _ in model.toggleClick() })) {
                Text("Click", comment: "Sidebar: the metronome switch")
            }
            .toggleStyle(.switch)
            .controlSize(.mini)
            .tooltip("Click on every beat of the grid | k")
            .accessibilityValue(Text(AccessibilityText.onOff(model.clickEnabled)))

            Spacer(minLength: 0)

            PillSlider(value: $model.clickGainDb,
                       range: InstrumentMixerState.minGainDb ... InstrumentMixerState.maxGainDb,
                       step: 0.1,
                       width: 70,
                       fill: Theme.volumeFill,
                       track: Theme.faderTrackTop,
                       thumb: Theme.faderThumb,
                       onDoubleClick: { model.clickGainDb = ProjectState.defaultClickGainDb },
                       valueText: String(localized: AccessibilityText.decibels(model.clickGainDb)))
                .tooltip("Click level | double-click for -6 dB")
                .accessibilityLabel(Text(AccessibilityText.clickLevel))
                .opacity(model.clickEnabled ? 1 : Theme.disabledAlpha)

            readout(model.clickGainDb)
        }
    }

    private func readout(_ db: Double) -> some View {
        Text(Formats.decibels(db))
            .font(.system(size: 11).monospacedDigit())
            .foregroundStyle(Theme.textMuted)
            .lineLimit(1)
            .frame(width: Self.valueWidth, alignment: .trailing)
            // The fader reads its own value.
            .accessibilityHidden(true)
    }
}

/// Original or MIDI as a momentary button: the hold starts on mouse-down and ends on release,
/// wherever the pointer went (a zero-distance drag). Bright while held, so the solo reads on the
/// label as well as on the slider.
private struct MixHoldLabel: View {
    let text: String
    let colour: Color
    let isHeld: Bool
    let begin: () -> Void
    let end: () -> Void

    @State private var isPressed = false

    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(isHeld ? Theme.textBright : colour)
            .fixedSize()
            // A little more than the glyphs, so the target is not the letter strokes alone.
            .padding(.vertical, 4)
            .contentShape(Rectangle())
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
            // A hold is not a press VoiceOver or the keyboard can make: for them the label
            // latches -- one press starts the solo, the next ends it (a11y design §2).
            .accessibleButton(Text(verbatim: text), isSelected: isHeld) {
                if isHeld {
                    end()
                } else {
                    begin()
                }
            }
            .accessibilityValue(Text(isHeld ? AccessibilityText.soloing : AccessibilityText.notSoloing))
    }
}
