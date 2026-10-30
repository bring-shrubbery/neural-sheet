import NeuralSheetCore
import SwiftUI

/// The transport, floating in glass over the bottom of the timeline and the score (native chrome
/// design §2): go to start, play / pause, record, loop and follow, the position, the speed, and a
/// run's progress at the trailing end while one is in flight. What the top bar and the status
/// bar's progress group carried, with the same commands, keys and tooltips.
struct TransportCapsule: View {
    let model: AppModel

    var body: some View {
        let canPlay = model.state.canPlay
        let recording = model.state == .recording || model.state == .countingIn

        HStack(spacing: 2) {
            CapsuleIconButton(isEnabled: canPlay, action: model.goToStart) {
                Image(systemName: "backward.end.fill")
            }
            .tooltip("Go to start | Enter")
            .accessibilityLabel(Text(AccessibilityText.goToStart))

            playButton(canPlay: canPlay)

            // Lit through the count-in as through the take (click design §2).
            CapsuleIconButton(isEnabled: model.canRecord, action: model.toggleRecord) {
                Circle()
                    .fill(recording ? Theme.rec : Theme.rec.opacity(0.45))
                    .frame(width: 13, height: 13)
            }
            .tooltip("Record | r")
            .accessibilityLabel(Text(AccessibilityText.record))
            .accessibilityValue(Text(AccessibilityText.recordState(model.state)))

            // Inventory §1.3 had this permanently disabled; it loops the marked range, or the
            // whole take, since the loop design.
            CapsuleIconButton(isOn: model.loopEnabled, isEnabled: canPlay, action: model.toggleLoop) {
                Image(systemName: "repeat")
            }
            .tooltip("Loop | l")
            .accessibilityLabel(Text(AccessibilityText.loop))
            .accessibilityValue(Text(AccessibilityText.onOff(model.loopEnabled)))

            CapsuleIconButton(isOn: model.followPlayhead, isEnabled: canPlay, action: { model.followPlayhead.toggle() }) {
                ZStack {
                    Icons.FollowPlayheadStroked()
                        .stroke(style: Icons.strokeStyle(scale: 1))
                    Icons.FollowPlayheadFlag()
                        .fill(.foreground)
                }
                .frame(width: 16, height: 16)
            }
            .tooltip("Center playhead | c")
            .accessibilityLabel(Text(AccessibilityText.centrePlayhead))
            .accessibilityValue(Text(AccessibilityText.onOff(model.followPlayhead)))

            divider

            PositionReadout(model: model)

            divider

            SpeedMenu(model: model)

            if model.state == .processing {
                divider
                TranscriptionProgress(model: model)
                    .padding(.horizontal, 6)
            } else if model.stemsExport != nil {
                divider
                StemsExportProgress(model: model)
                    .padding(.horizontal, 6)
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 52)
        .glassEffect(.regular, in: .capsule)
    }

    private var divider: some View {
        Rectangle()
            .fill(Theme.divStrong)
            .frame(width: 1, height: 24)
            .padding(.horizontal, 8)
            .accessibilityHidden(true)
    }

    /// The one button showing whichever action is available now: pause while it plays. On the
    /// accent, the capsule's primary control.
    private func playButton(canPlay: Bool) -> some View {
        Button(action: model.togglePlay) {
            Image(systemName: model.isPlaying ? "pause.fill" : "play.fill")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 40, height: 40)
                .background(Circle().fill(Theme.accent))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(!canPlay)
        .opacity(canPlay ? 1 : Theme.disabledAlpha)
        .padding(.horizontal, 2)
        .tooltip("Play / Pause | Space")
        .accessibilityLabel(Text(model.isPlaying ? AccessibilityText.pause : AccessibilityText.play))
        .accessibilityValue(Text(model.isPlaying ? AccessibilityText.playing : AccessibilityText.stopped))
    }
}

/// A round icon button for the floating capsules: the icon in the label colour, the accent while
/// it is on, a soft circle under the pointer.
struct CapsuleIconButton<Label: View>: View {
    var isOn = false
    var isEnabled = true
    let action: () -> Void
    @ViewBuilder let label: () -> Label

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            label()
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(isOn ? Theme.accent : Theme.textPrimary)
                .frame(width: 36, height: 36)
                .background(Circle().fill(isOn ? Theme.accentFillActive : (isHovered ? Theme.bgControlSubtle : .clear)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : Theme.disabledAlpha)
        .onHover { isHovered = $0 && isEnabled }
    }
}

// MARK: - Position

/// The position over the take's length, or the count-in's beats to go while it runs (click design
/// §2). The playhead moves every frame but the hundredths change every other one at most, so the
/// drawing is an `Equatable` leaf re-rendered only when its strings change.
private struct PositionReadout: View {
    let model: AppModel

    var body: some View {
        let readout = model.timeReadout
        let countIn = model.state == .countingIn ? model.countInRemaining : nil

        PositionReadoutBody(position: readout.position,
                            total: readout.total,
                            countIn: countIn,
                            isLive: model.state.canPlay)
            .equatable()
    }
}

private struct PositionReadoutBody: View, Equatable {
    let position: String
    let total: String
    let countIn: Int?
    /// A zero that cannot move is not a reading: the position is the label colour only once there
    /// is audio to play.
    let isLive: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            if let countIn {
                Text("Count-in \(StatusText.separator) \(countIn)", comment: "Status bar: the count-in's beats still to go")
                    .font(.system(size: 15, weight: .semibold).monospacedDigit())
                    .foregroundStyle(Theme.accent)
            } else {
                Text(verbatim: position)
                    .font(.system(size: 17, weight: .semibold).monospacedDigit())
                    .foregroundStyle(isLive ? Theme.textBright : Theme.textMuted)
            }

            Text(verbatim: "/ " + total)
                .font(.system(size: 11).monospacedDigit())
                .foregroundStyle(Theme.textMuted)
        }
        .fixedSize()
        .frame(minWidth: 96, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(AccessibilityText.position))
        .accessibilityValue(Text(AccessibilityText.positionValue(position, of: total)))
        .accessibilityAddTraits(.updatesFrequently)
    }
}

// MARK: - Speed

/// The playback speed (speed design §6) as a menu of steps from 50 to 150 %; `-` and `=` still
/// step it by 5 %, and the label shows wherever they leave it.
private struct SpeedMenu: View {
    let model: AppModel

    private static let choices: [Double] = [0.5, 0.6, 0.7, 0.75, 0.8, 0.9, 1.0, 1.1, 1.25, 1.5]

    var body: some View {
        let percent = Int((model.playbackSpeed * 100).rounded())

        Menu {
            ForEach(Self.choices, id: \.self) { speed in
                Toggle(Formats.percent(Int((speed * 100).rounded())), isOn: Binding(
                    get: { abs(model.playbackSpeed - speed) < 0.001 },
                    set: { if $0 { model.playbackSpeed = speed } }))
            }
        } label: {
            Text(Formats.percent(percent))
                .font(.system(size: 13, weight: .medium).monospacedDigit())
        }
        .menuStyle(.button)
        .buttonStyle(.borderless)
        .menuIndicator(.visible)
        .fixedSize()
        .disabled(!model.state.canPlay)
        .tooltip("Playback speed, pitch unchanged | - =")
        .accessibilityLabel(Text(AccessibilityText.playbackSpeed))
    }
}

// MARK: - Vertical zoom

/// The piano roll's vertical zoom, in a small glass capsule at the roll's bottom-right corner
/// (native chrome design §2): the status bar's icon and slider.
struct ZoomCapsule: View {
    let model: AppModel

    var body: some View {
        HStack(spacing: 8) {
            Icons.VerticalZoomStroked()
                .stroke(Theme.textIcon, style: Icons.strokeStyle(scale: 1))
                .frame(width: 12, height: 12)
                .accessibilityHidden(true)

            PillSlider(value: zoom,
                       range: 0 ... 1,
                       width: 90,
                       fill: Theme.zoomFill,
                       track: Theme.zoomTrack,
                       thumb: Theme.faderThumb,
                       valueText: String(localized: AccessibilityText.percent(Int((zoom.wrappedValue * 100).rounded()))))
                .tooltip("Piano roll vertical zoom | ⌥ + scroll or ⌥ + pinch on the roll")
                .accessibilityLabel(Text(AccessibilityText.verticalZoom))
        }
        .padding(.horizontal, 14)
        .frame(height: 34)
        .glassEffect(.regular, in: .capsule)
    }

    /// The slider reads the zoom, or the fit while it is automatic; moving it takes the zoom off
    /// automatic (§7.2).
    private var zoom: Binding<Double> {
        Binding(
            get: { model.verticalZoom < 0 ? model.fittedVerticalZoom : model.verticalZoom },
            set: { model.verticalZoom = $0 })
    }
}
