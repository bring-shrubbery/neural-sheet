import NeuralSheetCore
import SwiftUI

/// The transport bar (iOS app design §2, sub-issue H), pinned over the Roll and Score screens and
/// under the Transcribe screen once there is a take: Go to Start, Play/Pause, the position and
/// the length; the ORIG / MIDI mix with its holds and the stereo split; SPEED, Loop and CLICK;
/// the output level and MUTE (the Mac's master panel) in a popover; and on iPhone the strips in
/// a sheet (on iPad they are in the sidebar). One row on a regular width, two on a compact one.
struct TransportBar<Trailing: View>: View {
    let model: MobileModel
    @ViewBuilder let trailing: () -> Trailing

    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var showsStrips = false

    init(model: MobileModel, @ViewBuilder trailing: @escaping () -> Trailing) {
        self.model = model
        self.trailing = trailing
    }

    var body: some View {
        Group {
            if sizeClass == .regular {
                HStack(spacing: 8) {
                    transport
                    Spacer(minLength: 8)
                    MixControl(model: model)
                        .frame(maxWidth: 300)
                    SpeedButton(model: model)
                    practice
                    OutputButton(model: model)
                    trailing()
                }
                .frame(height: 52)
            } else {
                VStack(spacing: 0) {
                    HStack(spacing: 0) {
                        transport
                        Spacer(minLength: 0)
                        practice
                        trailing()
                    }
                    .frame(height: 48)

                    HStack(spacing: 4) {
                        MixControl(model: model)
                        SpeedButton(model: model)
                        OutputButton(model: model)
                        stripsButton
                    }
                    .frame(height: 44)
                }
            }
        }
        .padding(.horizontal, 8)
        .background(.bar)
        .sheet(isPresented: $showsStrips) {
            NavigationStack {
                List {
                    InstrumentStripsSection(model: model)
                }
                .navigationTitle(Text("Instruments", comment: "The strips sheet's title: the take's instruments"))
                .navigationBarTitleDisplayMode(.inline)
            }
            .presentationDetents([.medium, .large])
        }
    }

    // MARK: - Groups

    @ViewBuilder
    private var transport: some View {
        let playing = model.isTransportRunning

        TransportIconButton(systemImage: "backward.end.fill", id: "go-to-start",
                            label: Text("Go to Start", comment: "Transport: stop and rewind to the start")) {
            model.goToStart()
        }
        .disabled(!model.canPlay)

        TransportIconButton(systemImage: playing ? "pause.fill" : "play.fill", id: "play",
                            label: playing ? Text("Pause", comment: "Transport: pause playback")
                                           : Text("Play", comment: "Transport: start playback")) {
            model.togglePlay()
        }
        .font(.title2)
        .disabled(!model.canPlay)

        PositionText(model: model)
    }

    @ViewBuilder
    private var practice: some View {
        TransportToggle(systemImage: "repeat", isOn: model.loopEnabled, id: "loop",
                        label: Text("Loop", comment: "Transport: repeat the marked range, or the whole take")) {
            model.toggleLoop()
        }
        .disabled(!model.canPlay)

        TransportToggle(systemImage: "metronome", isOn: model.clickEnabled, id: "click",
                        label: Text("CLICK", comment: "Master panel: the metronome button")) {
            model.toggleClick()
        }
    }

    private var stripsButton: some View {
        TransportIconButton(systemImage: "slider.vertical.3", id: "strips",
                            label: Text("Instruments", comment: "Transport: opens the instrument strips")) {
            showsStrips = true
        }
    }
}

extension TransportBar where Trailing == EmptyView {
    /// The bar with nothing of the screen's own at its end: the Transcribe screen's.
    init(model: MobileModel) {
        self.init(model: model) { EmptyView() }
    }
}

/// A bar button with a 44-point target.
private struct TransportIconButton: View {
    let systemImage: String
    let id: String
    let label: Text
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .frame(width: 44, height: 44)
        }
        .accessibilityLabel(label)
        .accessibilityIdentifier(id)
    }
}

/// A switch on the bar: the icon in a tinted square while it is on, a 44-point target either way.
private struct TransportToggle: View {
    let systemImage: String
    let isOn: Bool
    let id: String
    let label: Text
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .frame(width: 34, height: 34)
                .background(RoundedRectangle(cornerRadius: 8).fill(isOn ? Color.accentColor.opacity(0.22) : .clear))
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .accessibilityLabel(label)
        .accessibilityAddTraits(isOn ? .isSelected : [])
        .accessibilityIdentifier(id)
    }
}

/// "0:12.3 / 2:45.0": the poll's position, in a view of its own so only it redraws thirty times a
/// second.
private struct PositionText: View {
    let model: MobileModel

    var body: some View {
        Text(verbatim: "\(TimeFormat.transport(model.positionSeconds)) / \(TimeFormat.transport(model.duration))")
            .font(.system(.caption, design: .monospaced))
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .fixedSize()
            .accessibilityLabel(Text("Position", comment: "Transport: the playhead's time"))
            .accessibilityValue(Text(verbatim: TimeFormat.transport(model.positionSeconds)))
            .accessibilityIdentifier("position")
    }
}

// MARK: - Mix

/// ORIG ... slider ... MIDI, and the stereo split beside it: the Mac's mix pill. Holding ORIG or
/// MIDI plays that side alone until the finger lifts; under the split the slider is inert and
/// the holds silence the other ear.
private struct MixControl: View {
    let model: MobileModel

    var body: some View {
        HStack(spacing: 2) {
            MixHoldLabel(text: String(localized: "ORIG", comment: "Master panel: the mix slider's source-audio end; held, only the source plays"),
                         isHeld: model.mixHold == 0, id: "mix-orig") {
                model.beginMixHold(.source)
            } end: {
                model.endMixHold()
            }

            Slider(value: Binding(get: { model.effectiveMix }, set: { model.setMix($0) }), in: 0 ... 1)
                .disabled(model.stereoSplit || !model.canPlay)
                .accessibilityLabel(Text("Mix", comment: "Transport: the ORIG / MIDI crossfade"))
                .accessibilityValue(Text(verbatim: "\(Int((model.effectiveMix * 100).rounded())) %"))
                .accessibilityIdentifier("mix")

            MixHoldLabel(text: String(localized: "MIDI", comment: "Master panel: the mix slider's MIDI end; held, only the MIDI plays"),
                         isHeld: model.mixHold == 1, id: "mix-midi") {
                model.beginMixHold(.synth)
            } end: {
                model.endMixHold()
            }

            TransportToggle(systemImage: "headphones", isOn: model.stereoSplit, id: "split",
                            label: Text("Stereo split", comment: "Transport: the original in the left ear, the MIDI in the right")) {
                model.setStereoSplit(!model.stereoSplit)
            }
        }
    }
}

/// ORIG or MIDI as a momentary button: the hold starts on touch-down and ends on lift, wherever
/// the finger went, as the Mac's label does with the mouse. For VoiceOver it latches.
private struct MixHoldLabel: View {
    let text: String
    let isHeld: Bool
    let id: String
    let begin: () -> Void
    let end: () -> Void

    @State private var isPressed = false

    var body: some View {
        Text(verbatim: text)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(isHeld ? Color.primary : Color.secondary)
            .frame(minWidth: 36, minHeight: 44)
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
            .accessibilityElement()
            .accessibilityLabel(Text(verbatim: text))
            .accessibilityAddTraits(isHeld ? [.isButton, .isSelected] : .isButton)
            .accessibilityAction { isHeld ? end() : begin() }
            .accessibilityIdentifier(id)
    }
}

// MARK: - Speed

/// "100%", opening the speed slider: 50 … 150 %, pitch held, with Reset.
private struct SpeedButton: View {
    let model: MobileModel

    @State private var isShown = false

    var body: some View {
        Button { isShown = true } label: {
            Text(Formats.percent(Int((model.playbackSpeed * 100).rounded())))
                .font(.system(.footnote, design: .monospaced))
                .frame(minWidth: 52, minHeight: 44)
        }
        .disabled(!model.canPlay)
        .accessibilityLabel(Text("Playback speed", comment: "Transport: how fast the take plays, pitch unchanged"))
        .accessibilityIdentifier("speed")
        .popover(isPresented: $isShown) {
            SpeedPopover(model: model)
                .presentationCompactAdaptation(.popover)
        }
    }
}

private struct SpeedPopover: View {
    let model: MobileModel

    var body: some View {
        let percent = Int((model.playbackSpeed * 100).rounded())

        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("SPEED", comment: "The speed pill's caption")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Text(Formats.percent(percent))
                    .font(.body.monospacedDigit())
            }

            Slider(value: Binding(get: { model.playbackSpeed }, set: { model.setPlaybackSpeed($0) }),
                   in: TransportCommands.speedRange, step: TransportCommands.speedStep) {
                Text("Playback speed", comment: "Transport: how fast the take plays, pitch unchanged")
            } minimumValueLabel: {
                Text(Formats.percent(50)).font(.caption2)
            } maximumValueLabel: {
                Text(Formats.percent(150)).font(.caption2)
            }
            .accessibilityValue(Text(Formats.percent(percent)))
            .accessibilityIdentifier("speed-slider")

            HStack {
                Text("Pitch unchanged", comment: "The speed popover: the take's pitch does not follow its speed")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Spacer()
                Button { model.resetSpeed() } label: {
                    Text("Reset", comment: "The speed popover: back to the take's own speed")
                }
                .disabled(percent == 100)
                .accessibilityIdentifier("speed-reset")
            }
        }
        .padding()
        .frame(width: 300)
    }
}

// MARK: - Output

/// The speaker, opening the output: its meter, level and MUTE, and the click's level -- the
/// Mac's master panel.
private struct OutputButton: View {
    let model: MobileModel

    @State private var isShown = false

    var body: some View {
        Button { isShown = true } label: {
            Image(systemName: model.outputMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                .frame(width: 44, height: 44)
        }
        .accessibilityLabel(Text("MASTER", comment: "The master panel's header"))
        .accessibilityIdentifier("output")
        .popover(isPresented: $isShown) {
            OutputPopover(model: model)
                .presentationCompactAdaptation(.popover)
        }
    }
}

private struct OutputPopover: View {
    let model: MobileModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("MASTER", comment: "The master panel's header")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Toggle(isOn: Binding(get: { model.outputMuted }, set: { _ in model.toggleOutputMuted() })) {
                    Label { Text("MUTE", comment: "Master panel: the input mute button") } icon: {
                        Image(systemName: "speaker.slash.fill")
                    }
                    .font(.caption.weight(.semibold))
                }
                .toggleStyle(.button)
                .tint(.red)
                .accessibilityIdentifier("mute")
            }

            MasterMeter(model: model)

            GainSlider(value: model.masterGainDb, id: "master-gain",
                       label: Text("Output level", comment: "The master panel: the output's fader")) { db, _ in
                model.setMasterGain(db: db)
            } ended: {}

            Divider()

            Text("CLICK", comment: "Master panel: the metronome button")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            GainSlider(value: model.clickGainDb, id: "click-gain",
                       label: Text("Click level", comment: "The master panel: the click's fader")) { db, dragging in
                model.setClickGain(db: db, dragging: dragging)
            } ended: {
                model.endMixDrag()
            }
        }
        .padding()
        .frame(width: 300)
    }
}

/// The output's meter, in a view of its own so only it redraws with the poll.
private struct MasterMeter: View {
    let model: MobileModel

    var body: some View {
        LevelBar(db: model.masterLevelDb, segments: 26)
            .frame(height: 6)
            .accessibilityHidden(true)
    }
}

/// A fader, −36 (silence) … +6 dB in tenths, with its value: `change` hears whether the finger is
/// still down, `ended` when it lifts.
struct GainSlider: View {
    let value: Double
    let id: String
    let label: Text
    let change: (Double, Bool) -> Void
    let ended: () -> Void

    @State private var isDragging = false

    var body: some View {
        HStack(spacing: 8) {
            Slider(value: Binding(get: { value }, set: { change($0, isDragging) }),
                   in: InstrumentMixerState.minGainDb ... InstrumentMixerState.maxGainDb,
                   step: InstrumentMixerState.gainStepDb) {
                label
            } onEditingChanged: { editing in
                isDragging = editing

                if !editing { ended() }
            }
            .accessibilityValue(Text(verbatim: GainSlider.text(value)))
            .accessibilityIdentifier(id)

            Text(verbatim: GainSlider.text(value))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 52, alignment: .trailing)
        }
    }

    /// "−∞" at the silent end, "+1.5 dB" above.
    static func text(_ db: Double) -> String {
        guard db > InstrumentMixerState.minGainDb else { return "−∞" }

        return String(format: "%+.1f dB", db).replacingOccurrences(of: "-", with: "−")
    }
}

/// A segmented level meter on the Mac's scale (`MeterScale`): green, then amber from −12 dB, red
/// from −6 dB.
struct LevelBar: View {
    let db: Double
    let segments: Int

    var body: some View {
        let lit = MeterScale.litSegments(db: db, count: segments)

        HStack(spacing: 1) {
            ForEach(0 ..< segments, id: \.self) { segment in
                Rectangle()
                    .fill(colour(segment).opacity(segment < lit ? 1 : 0.15))
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 1.5))
    }

    private func colour(_ segment: Int) -> Color {
        switch MeterScale.band(segment: segment, count: segments) {
        case .low: .green
        case .mid: .yellow
        case .hot: .red
        }
    }
}
