import AppKit
import NeuralSheetCore
import SwiftUI

/// One instrument's row in the sidebar (`InstrumentStrip`, §1.5): colour dot, name, note count
/// and range, mute, solo, a fader with its readout, and the level meter under it with the pan
/// beside it (click design §2). A rounded row in the glass sidebar (native chrome design §4), as
/// wide as the sidebar's column.
///
/// The row is a function of the three values it is handed -- the entry, its mix settings and its
/// smoothed level -- and it talks back to the model only through the mixer commands. The model
/// reference is compared by identity, so a strip whose inputs have not changed is not re-laid out
/// when a neighbour's meter moves.
struct InstrumentStrip: View {
    let model: AppModel
    let entry: InstrumentEntry
    let settings: InstrumentChannelSettings
    /// The instrument's level after ballistics, in dB.
    let level: Double
    /// The strip's own width in points: the sidebar's column less its side margins.
    var width: CGFloat = SidebarMetrics.stripWidth
    /// Edit tab: this strip's instrument is where new and reassigned notes go (design §6.2).
    var isTarget = false
    /// This strip's instrument is singled out in the roll, the others faded; the dot takes an
    /// accent ring so the sidebar says so without competing with the roll.
    var isHighlighted = false
    /// A click on the dot or the name: toggles the highlight, and in the Edit tab makes this the
    /// target too. Nil for a strip that cannot be clicked.
    var onSelect: (() -> Void)?
    /// A secondary click anywhere on the strip: opens the strip card in the Edit tab (region
    /// design §6.1). Nil, and no catcher is installed, in the Transcribe tab.
    var onSecondaryClick: ((NSWindow, CGPoint) -> Void)?

    // MARK: - Extents

    private static let padding: CGFloat = 8
    private static let dotSize: CGFloat = 24
    /// Dot (24) + gap (8): where the name, the fader and the meter start.
    private static let textInset: CGFloat = 32
    private static let toggleSize: CGFloat = 24
    private static let valueWidth: CGFloat = 38
    private static let panWidth: CGFloat = 44
    private static let meterSegments = 20
    private static let meterHeight: CGFloat = 3
    private static let meterGap: CGFloat = 2
    /// The pan slider's ends, −100 (left) … +100 (right), and the detent either side of the
    /// centre that snaps to it (click design §2).
    private static let panSpan = 100.0
    private static let panDetent = 5.0

    var body: some View {
        let muted = settings.muted
        let alpha = muted ? Theme.mutedAlpha : 1.0
        let colour = Color(instrument: entry.info.colour)
        let contentWidth = width - 2 * Self.padding
        let faderWidth = contentWidth - Self.textInset - Self.valueWidth - 8

        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                // The dot and the name are one click target in the Edit tab: the strip becomes the
                // target instrument. Inert in the Transcribe tab.
                HStack(spacing: 8) {
                    dot(colour: colour, alpha: alpha)

                    VStack(alignment: .leading, spacing: 1) {
                        Text(entry.info.localizedName)
                            .font(.system(size: 13, weight: .medium))
                            .strikethrough(muted)
                            .foregroundStyle((muted ? Theme.textLabel : Theme.textPrimary).opacity(alpha))
                            .lineLimit(1)
                            .truncationMode(.tail)

                        Text(meta)
                            .font(.system(size: 11).monospacedDigit())
                            .foregroundStyle(Theme.textMuted.opacity(alpha))
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .contentShape(Rectangle())
                .onTapGesture { onSelect?() }
                .allowsHitTesting(onSelect != nil)
                // The name as a button that singles the instrument out, its counts as the value
                // (a11y design §2).
                .accessibleButton(Text(verbatim: entry.info.localizedName), isEnabled: onSelect != nil, isSelected: isHighlighted) {
                    onSelect?()
                }
                .accessibilityValue(Text(verbatim: meta))

                toggle(isOn: muted,
                       onColour: Theme.warn,
                       tooltip: "Mute this instrument",
                       accessibilityName: Text(AccessibilityText.mute)) {
                    Image(systemName: muted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                        .font(.system(size: 11, weight: .medium))
                } action: {
                    model.setMuted(program: entry.program, !muted)
                }

                toggle(isOn: settings.soloed,
                       onColour: Theme.rec,
                       tooltip: "Solo this instrument",
                       accessibilityName: Text(AccessibilityText.solo)) {
                    Text("S", comment: "Instrument strip: the solo toggle's letter")
                        .font(.system(size: 11, weight: .bold))
                } action: {
                    model.setSoloed(program: entry.program, !settings.soloed)
                }
            }

            // The fader under the name, the readout at the right.
            HStack(spacing: 8) {
                PillSlider(value: gain,
                           range: InstrumentMixerState.minGainDb ... InstrumentMixerState.maxGainDb,
                           step: InstrumentMixerState.gainStepDb,
                           width: faderWidth,
                           fill: muted ? Theme.faderFillMuted : colour.opacity(0.9),
                           track: Theme.faderTrack,
                           thumb: muted ? Theme.faderThumbMuted : Theme.faderThumb,
                           onDoubleClick: { model.setGain(program: entry.program, db: 0) },
                           valueText: String(localized: AccessibilityText.decibels(settings.gainDb)))
                    .disabled(entry.isPlaceholder)
                    .opacity(alpha)
                    .tooltip("Level for this instrument")
                    .accessibilityLabel(Text(AccessibilityText.level))

                Text(Formats.decibels(settings.gainDb))
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(Theme.textMuted.opacity(alpha))
                    .lineLimit(1)
                    .frame(width: Self.valueWidth, alignment: .trailing)
                    // The fader reads its own value.
                    .accessibilityHidden(true)
            }
            .padding(.leading, Self.textInset)

            // The meter takes the fader's own width, so the two line up under the name; the pan
            // takes the readout's column.
            HStack(spacing: 8) {
                LevelMeter(db: level, segments: Self.meterSegments, gap: Self.meterGap, height: Self.meterHeight)
                    .frame(width: faderWidth)
                    .opacity(alpha)

                PillSlider(value: pan,
                           range: -Self.panSpan ... Self.panSpan,
                           step: 1,
                           width: Self.valueWidth,
                           fill: Theme.faderTrack,
                           track: Theme.faderTrack,
                           thumb: muted ? Theme.faderThumbMuted : Theme.faderThumb,
                           onDoubleClick: { model.setPan(program: entry.program, 0) },
                           valueText: String(localized: AccessibilityText.pan(settings.pan)))
                    .disabled(entry.isPlaceholder)
                    .opacity(alpha)
                    .tooltip("Pan | double-click to centre")
                    .accessibilityLabel(Text(AccessibilityText.panLabel))
            }
            .padding(.leading, Self.textInset)
        }
        .padding(Self.padding)
        .frame(width: width, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(rowFill))
        .overlay {
            if let onSecondaryClick {
                RightClickCatcher(onRightClick: onSecondaryClick,
                                  accessibilityTitle: String(localized: AccessibilityText.instrumentCommands))
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(verbatim: entry.info.localizedName))
    }

    // MARK: - Pieces

    /// The target instrument's row on the accent, a soloed one on the solo colour.
    private var rowFill: Color {
        if isTarget { return Theme.accentFillActive }
        if settings.soloed { return Theme.soloRowTint }

        return .clear
    }

    /// The instrument's colour as a filled dot with its abbreviation; an accent ring while it is
    /// singled out in the roll.
    private func dot(colour: Color, alpha: Double) -> some View {
        Circle()
            .fill(colour.opacity(alpha))
            .overlay {
                Text(entry.info.abbreviation)
                    .font(.system(size: 7.5, weight: .bold))
                    .foregroundStyle(.white.opacity(alpha))
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                    .padding(2)
            }
            .overlay {
                if isHighlighted {
                    Circle().strokeBorder(Theme.accent, lineWidth: 2).padding(-3)
                }
            }
            .frame(width: Self.dotSize, height: Self.dotSize)
            .accessibilityHidden(true)
    }

    /// A round toggle: the label in the secondary colour, on its colour's tint while on.
    private func toggle<Label: View>(isOn: Bool,
                                     onColour: Color,
                                     tooltip: LocalizedStringResource,
                                     accessibilityName: Text,
                                     @ViewBuilder label: () -> Label,
                                     action: @escaping () -> Void) -> some View {
        Button(action: action) {
            label()
                .foregroundStyle(isOn ? onColour : Theme.textIcon)
                .frame(width: Self.toggleSize, height: Self.toggleSize)
                .background(Circle().fill(isOn ? onColour.opacity(0.18) : Theme.bgControl))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(entry.isPlaceholder)
        .tooltip(tooltip)
        // A glyph says nothing read aloud: the toggle is named, its state the value.
        .accessibilityLabel(accessibilityName)
        .accessibilityValue(Text(AccessibilityText.onOff(isOn)))
    }

    // MARK: - Derived

    /// The fader as a binding over the mixer: reads the settings it was handed, writes through the
    /// model.
    private var gain: Binding<Double> {
        Binding(get: { settings.gainDb },
                set: { model.setGain(program: entry.program, db: $0) })
    }

    /// The pan as the slider shows it, −100…100, writing −1…1 through the model; within the
    /// detent of the centre it is the centre.
    private var pan: Binding<Double> {
        Binding(get: { settings.pan * Self.panSpan },
                set: { value in
                    let snapped = abs(value) < Self.panDetent ? 0 : value
                    model.setPan(program: entry.program, snapped / Self.panSpan)
                })
    }

    /// Drums have no pitch range to report: their key numbers name pieces of a kit, not notes.
    private var meta: String {
        let separator = " \u{00B7} "

        if entry.isPlaceholder {
            return String(localized: "selected", comment: "Instrument strip: an instrument chosen for the next run")
                + separator + String(localized: "not transcribed yet", comment: "Instrument strip: no notes for it yet")
        }

        if entry.program == NoteEvent.drumProgram {
            return String(localized: "\(entry.noteCount) hits", comment: "Instrument strip: how many drum hits")
                + separator + String(localized: "kit map", comment: "Instrument strip: the drums' notes name kit pieces, not pitches")
        }

        return String(localized: "\(entry.noteCount) notes", comment: "Instrument strip: how many notes")
            + separator + TimeFormat.pitchName(entry.lowestPitch) + "-" + TimeFormat.pitchName(entry.highestPitch)
    }
}

/// Main-actor isolated, as the view is: the comparison only ever runs on the main thread, and
/// it needs to look at the target closure.
extension InstrumentStrip: @MainActor Equatable {
    /// The model is one object for the life of the window, so identity is the comparison; the rest
    /// is the strip's inputs, and a strip whose inputs stand still is left alone. The select
    /// closure is compared by presence only: it is the same call for the life of the window, and
    /// what it does on a click is the model's decision, not the strip's -- the two closures are
    /// compared by presence only.
    static func == (lhs: InstrumentStrip, rhs: InstrumentStrip) -> Bool {
        lhs.model === rhs.model
            && lhs.entry == rhs.entry
            && lhs.settings == rhs.settings
            && lhs.level == rhs.level
            && lhs.width == rhs.width
            && lhs.isTarget == rhs.isTarget
            && lhs.isHighlighted == rhs.isHighlighted
            && (lhs.onSelect == nil) == (rhs.onSelect == nil)
            && (lhs.onSecondaryClick == nil) == (rhs.onSecondaryClick == nil)
    }
}

#Preview("Instrument strips") {
    let model = AppModel()

    func entry(_ program: Int, notes: Int, low: Int = 36, high: Int = 79) -> InstrumentEntry {
        InstrumentEntry(program: program,
                        info: Instruments.info(forProgram: program),
                        noteCount: notes,
                        lowestPitch: low,
                        highestPitch: high)
    }

    return VStack(spacing: 0) {
        InstrumentStrip(model: model,
                        entry: entry(0, notes: 0),
                        settings: InstrumentChannelSettings(),
                        level: MeterScale.minDb)
        InstrumentStrip(model: model,
                        entry: entry(24, notes: 312, low: 40, high: 76),
                        settings: InstrumentChannelSettings(gainDb: -3),
                        level: -9)
        InstrumentStrip(model: model,
                        entry: entry(33, notes: 128, low: 28, high: 52),
                        settings: InstrumentChannelSettings(gainDb: 0, muted: true),
                        level: MeterScale.minDb)
        InstrumentStrip(model: model,
                        entry: entry(56, notes: 88, low: 55, high: 84),
                        settings: InstrumentChannelSettings(gainDb: 2.5, soloed: true),
                        level: -4)
        InstrumentStrip(model: model,
                        entry: entry(NoteEvent.drumProgram, notes: 640),
                        settings: InstrumentChannelSettings(),
                        level: -20)
    }
    .background(Theme.bgSidebar)
    .frame(width: 262)
}
