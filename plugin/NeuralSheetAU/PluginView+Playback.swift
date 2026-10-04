import NeuralSheetCore
import SwiftUI

/// The plugin's transport and mix (Audio Unit design §2, "UI"): Go to start and Play / Pause of the
/// plugin's own transport (waiting while the host plays), where the playhead is and whose it is,
/// the ORIG / MIDI mix and the master.
struct PlaybackBar: View {
    @Bindable var playback: PluginPlayback

    var body: some View {
        HStack(spacing: 12) {
            HStack(spacing: 6) {
                Button("Go to Start", systemImage: "backward.end.fill", action: playback.goToStart)
                    .labelStyle(.iconOnly)
                Button(playback.isPlaying ? "Pause" : "Play",
                       systemImage: playback.isPlaying ? "pause.fill" : "play.fill",
                       action: playback.togglePlay)
                    .labelStyle(.iconOnly)
                    .disabled(playback.hostPlaying)
            }

            PlayheadReadout(playback: playback)

            Spacer(minLength: 8)

            HStack(spacing: 6) {
                Text("ORIG")
                Slider(value: $playback.mix, in: 0...1)
                    .frame(width: 110)
                    .help("The host's audio against the synth")
                Text("MIDI")
            }

            HStack(spacing: 6) {
                Text("Master")
                Slider(value: $playback.masterGainDb, in: InstrumentMixerState.minGainDb...InstrumentMixerState.maxGainDb)
                    .frame(width: 90)
                Text(DecibelText.text(playback.masterGainDb))
                    .frame(width: 52, alignment: .trailing)
            }
        }
        .font(.callout)
        .monospacedDigit()
        .foregroundStyle(.secondary)
    }
}

/// Where the playhead is and whose transport moves it, refreshed while anything plays.
private struct PlayheadReadout: View {
    let playback: PluginPlayback

    var body: some View {
        TimelineView(.periodic(from: .now, by: playback.isPlaying || playback.hostPlaying ? 1.0 / 15 : 1)) { _ in
            HStack(spacing: 8) {
                Text(TimeFormat.transport(max(playback.playheadSeconds ?? 0, 0)))
                Text(playback.hostPlaying ? "Host playing" : "Host stopped")
                    .foregroundStyle(.tertiary)
            }
        }
    }
}

/// The transcription's ways into the host -- Send MIDI to host -- over one row per instrument, as
/// the Mac's sidebar has them without pan or meters: the colour, the name, mute, solo and the
/// fader.
struct StripList: View {
    let playback: PluginPlayback

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            MidiExits(playback: playback)
                .padding(10)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(playback.mixer.entries, id: \.program) { entry in
                        StripRow(playback: playback, entry: entry)
                    }
                }
                .padding(10)
            }
        }
        .frame(width: 210)
        .background(.quaternary.opacity(0.5), in: .rect(cornerRadius: 6))
    }
}

/// Send MIDI to host, and what went wrong turning it on.
private struct MidiExits: View {
    let playback: PluginPlayback

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Toggle("Send MIDI to host", isOn: Binding(get: { playback.sendsMIDI },
                                                      set: { playback.setSendsMIDI($0) }))
                .help("Record from the “NeuralSheet Plugin” MIDI source on a MIDI track")

            if playback.midiFailed {
                Text("The MIDI source could not be created.")
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
    }
}

private struct StripRow: View {
    let playback: PluginPlayback
    let entry: InstrumentEntry

    var body: some View {
        let program = entry.program
        let mixer = playback.mixer

        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                RoundedRectangle(cornerRadius: 3)
                    .fill(Color(.sRGB, red: entry.info.colour.r, green: entry.info.colour.g, blue: entry.info.colour.b,
                                opacity: entry.info.colour.a))
                    .frame(width: 12, height: 12)
                Text(entry.info.name)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .opacity(mixer.isAudible(program: program) ? 1 : 0.5)
                Spacer(minLength: 4)
                Toggle("M", isOn: Binding(get: { mixer.isMuted(program: program) },
                                          set: { _ in playback.toggleMute(program: program) }))
                    .help("Mute")
                Toggle("S", isOn: Binding(get: { mixer.isSoloed(program: program) },
                                          set: { _ in playback.toggleSolo(program: program) }))
                    .help("Solo")
            }
            .toggleStyle(.button)
            .controlSize(.small)

            HStack(spacing: 6) {
                Slider(value: Binding(get: { mixer.gainDb(program: program) },
                                      set: { playback.setGain(program: program, db: $0) }),
                       in: InstrumentMixerState.minGainDb...InstrumentMixerState.maxGainDb)
                    .controlSize(.small)
                Text(DecibelText.text(mixer.gainDb(program: program)))
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(width: 46, alignment: .trailing)
            }
        }
    }
}

/// A fader's value as the Mac's strips show it: −∞ at the silent end, one decimal otherwise.
enum DecibelText {
    static func text(_ db: Double) -> String {
        if db <= InstrumentMixerState.minGainDb { return "−∞ dB" }
        let value = db.formatted(.number.precision(.fractionLength(1)))
        return "\(value) dB"
    }
}
