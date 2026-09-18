import AppKit
import NeuralSheetCore
import SwiftUI

/// One instrument's row in the sidebar (`InstrumentStrip`, §1.5): colour chip, name, note count
/// and range, mute, solo, a fader and the level meter under it. 76 authored points tall, as wide
/// as the sidebar's strip column.
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
    /// The strip's own width in authored points: the sidebar's column, which is the sidebar less
    /// its 1 px border.
    var width: CGFloat = SidebarMetrics.stripWidth

    @Environment(\.uiScale) private var k

    // MARK: - Authored extents (`InstrumentStrip.cpp`, `nn::metrics`)

    private static let paddingSide: CGFloat = 14
    private static let paddingTop: CGFloat = 11
    private static let identityRowHeight: CGFloat = 22
    private static let toggleWidth: CGFloat = 20
    private static let toggleHeight: CGFloat = 18
    private static let toggleGap: CGFloat = 3
    private static let toggleCorner: CGFloat = 4
    /// Between the name column and the toggles.
    private static let toggleTextGap: CGFloat = 8
    private static let faderTopGap: CGFloat = 9
    private static let faderHeight: CGFloat = 11
    private static let valueWidth: CGFloat = 30
    private static let valueGap: CGFloat = 9
    private static let chipSize: CGFloat = 22
    private static let chipCorner: CGFloat = 5
    /// Chip (22) + gap (9): where the name, the fader and the meter start.
    private static let textInset: CGFloat = 31
    private static let metaGap: CGFloat = 2
    private static let meterTopGap: CGFloat = 6
    private static let meterHeight: CGFloat = 3
    private static let meterSegments = 16
    private static let meterGap: CGFloat = 2

    /// The name row is the name font's own line height, rounded, as JUCE split the identity row.
    /// Measured from the face rather than written down so the split follows the font.
    private static let nameRowHeight: CGFloat = {
        guard let font = NSFont(name: Fonts.Name.interMedium, size: Fonts.Size.instrumentName) else { return 15 }

        return (font.ascender - font.descender).rounded()
    }()

    var body: some View {
        let s = Scaled(k: k)
        let muted = settings.muted
        let alpha = muted ? Theme.mutedAlpha : 1.0
        let colour = Color(entry.info.colour)
        let contentWidth = width - 2 * Self.paddingSide
        let faderWidth = contentWidth - Self.textInset - Self.valueWidth - Self.valueGap

        VStack(alignment: .leading, spacing: 0) {
            // Identity row: chip, name over meta, and the M/S pair.
            HStack(alignment: .top, spacing: 0) {
                chip(colour: colour, alpha: alpha, s: s)

                VStack(alignment: .leading, spacing: 0) {
                    ZStack(alignment: .leading) {
                        Text(entry.info.name)
                            .font(Fonts.instrumentName(k))
                            .foregroundStyle((muted ? Theme.textLabel : Theme.textStrong).opacity(alpha))
                            .lineLimit(1)
                            .truncationMode(.tail)

                        if muted {
                            // A 1 px line across the name's own width, at the row's centre.
                            Rectangle()
                                .fill(Theme.textLabel.opacity(alpha))
                                .frame(width: min(nameWidth(), s(nameColumnWidth(contentWidth))), height: k)
                        }
                    }
                    .frame(height: s(Self.nameRowHeight), alignment: .leading)

                    Text(meta)
                        .font(Fonts.meta(k))
                        .foregroundStyle(Theme.textFaintest.opacity(alpha))
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .frame(height: s(Self.identityRowHeight - Self.nameRowHeight - Self.metaGap))
                        .padding(.top, s(Self.metaGap))
                }
                .frame(width: s(nameColumnWidth(contentWidth)), height: s(Self.identityRowHeight), alignment: .topLeading)
                .padding(.leading, s(Self.textInset - Self.chipSize))

                Spacer(minLength: 0)

                HStack(spacing: s(Self.toggleGap)) {
                    toggle("M",
                           isOn: muted,
                           onBackground: Theme.bgMuteActive,
                           onText: Theme.warn,
                           tooltip: "Mute this instrument",
                           s: s) { model.setMuted(program: entry.program, !muted) }

                    toggle("S",
                           isOn: settings.soloed,
                           onBackground: Theme.soloButtonBg,
                           onText: Theme.rec,
                           tooltip: "Solo this instrument",
                           s: s) { model.setSoloed(program: entry.program, !settings.soloed) }
                }
                .opacity(alpha)
                .frame(height: s(Self.identityRowHeight))
            }
            .frame(height: s(Self.identityRowHeight))

            // Fader row: the fader under the name, the readout at the right.
            HStack(spacing: 0) {
                PillSlider(value: gain,
                           range: InstrumentMixerState.minGainDb ... InstrumentMixerState.maxGainDb,
                           step: InstrumentMixerState.gainStepDb,
                           width: s(faderWidth),
                           fill: muted ? Theme.faderFillMuted : colour.opacity(0.85),
                           track: Theme.faderTrack,
                           thumb: muted ? Theme.faderThumbMuted : Theme.faderThumb,
                           onDoubleClick: { model.setGain(program: entry.program, db: 0) })
                    .disabled(entry.isPlaceholder)
                    .opacity(alpha)
                    .tooltip("Level for this instrument")
                    .padding(.leading, s(Self.textInset))

                Spacer(minLength: 0)

                Text(TimeFormat.decibels(settings.gainDb))
                    .font(Fonts.meta(k))
                    .foregroundStyle(Theme.textDim.opacity(alpha))
                    .lineLimit(1)
                    .frame(width: s(Self.valueWidth), height: s(Self.faderHeight), alignment: .trailing)
            }
            .frame(height: s(Self.faderHeight))
            .padding(.top, s(Self.faderTopGap))

            // The meter takes the fader's own insets, so the two line up under the name.
            LevelMeter(db: level, segments: Self.meterSegments, gap: Self.meterGap, height: Self.meterHeight)
                .frame(width: s(faderWidth))
                .opacity(alpha)
                .padding(.leading, s(Self.textInset))
                .padding(.top, s(Self.meterTopGap))

            Spacer(minLength: 0)
        }
        .padding(.horizontal, s(Self.paddingSide))
        .padding(.top, s(Self.paddingTop))
        .frame(width: s(width), height: s(SidebarMetrics.stripHeight), alignment: .topLeading)
        .background(settings.soloed ? Theme.soloRowTint : Color.clear)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Theme.divRow)
                .frame(height: k)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(entry.info.name)
    }

    // MARK: - Pieces

    private func chip(colour: Color, alpha: Double, s: Scaled) -> some View {
        let shape = RoundedRectangle(cornerRadius: s(Self.chipCorner), style: .circular)

        // Fill, border and label each carry the muted alpha on their own colour, as the original
        // multiplied it in, rather than as one group: the border overlaps the fill.
        return ZStack {
            shape.fill(Theme.chipFill(colour).opacity(alpha))
            shape.strokeBorder(Theme.chipBorder(colour).opacity(alpha), lineWidth: k)
            Text(entry.info.abbreviation)
                .font(Fonts.mono(8, weight: 600, scale: k))
                .foregroundStyle(colour.opacity(alpha))
                .lineLimit(1)
        }
        .frame(width: s(Self.chipSize), height: s(Self.chipSize))
    }

    private func toggle(_ label: String,
                        isOn: Bool,
                        onBackground: Color,
                        onText: Color,
                        tooltip: String,
                        s: Scaled,
                        action: @escaping () -> Void) -> some View {
        FlatButton(isOn: isOn,
                   isEnabled: !entry.isPlaceholder,
                   idle: Theme.bgControlSubtle,
                   on: onBackground,
                   foregroundIdle: Theme.textDim,
                   foregroundOn: onText,
                   corner: s(Self.toggleCorner),
                   action: action) { _ in
            Text(label)
                .font(Fonts.metaStrong(k))
                .frame(width: s(Self.toggleWidth), height: s(Self.toggleHeight))
        }
        .tooltip(tooltip)
    }

    // MARK: - Derived

    /// The fader as a binding over the mixer: reads the settings it was handed, writes through the
    /// model.
    private var gain: Binding<Double> {
        Binding(get: { settings.gainDb },
                set: { model.setGain(program: entry.program, db: $0) })
    }

    /// How wide the name and meta column is: the row less the chip and the toggles.
    private func nameColumnWidth(_ contentWidth: CGFloat) -> CGFloat {
        contentWidth - Self.textInset - (2 * Self.toggleWidth + Self.toggleGap + Self.toggleTextGap)
    }

    /// The name's rendered width, for the strike-through: the line runs under the text, not the
    /// column.
    private func nameWidth() -> CGFloat {
        guard let font = NSFont(name: Fonts.Name.interMedium, size: Fonts.Size.instrumentName * k) else { return 0 }

        return (entry.info.name as NSString).size(withAttributes: [.font: font]).width
    }

    /// Drums have no pitch range to report: their key numbers name pieces of a kit, not notes.
    private var meta: String {
        let separator = " \u{00B7} "

        if entry.isPlaceholder {
            return "selected" + separator + "not transcribed yet"
        }

        if entry.program == NoteEvent.drumProgram {
            return "\(entry.noteCount) hits" + separator + "kit map"
        }

        return "\(entry.noteCount) notes" + separator
            + TimeFormat.pitchName(entry.lowestPitch) + "-" + TimeFormat.pitchName(entry.highestPitch)
    }
}

extension InstrumentStrip: Equatable {
    /// The model is one object for the life of the window, so identity is the comparison; the rest
    /// is the strip's inputs, and a strip whose inputs stand still is left alone.
    nonisolated static func == (lhs: InstrumentStrip, rhs: InstrumentStrip) -> Bool {
        lhs.model === rhs.model
            && lhs.entry == rhs.entry
            && lhs.settings == rhs.settings
            && lhs.level == rhs.level
            && lhs.width == rhs.width
    }
}

private extension Color {
    /// The model's own colour type, which is what an instrument's palette entry arrives as. File
    /// scope: the piano roll makes the same conversion for its notes, and two visible overloads
    /// would collide.
    init(_ rgba: NeuralSheetCore.RGBA) {
        self.init(.sRGB, red: rgba.r, green: rgba.g, blue: rgba.b, opacity: rgba.a)
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
