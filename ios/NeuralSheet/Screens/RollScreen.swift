import NeuralSheetCore
import SwiftUI

/// The roll screen (iOS app design §2, sub-issue E): the touch timeline under a placeholder
/// transport -- Play/Pause and the position -- until sub-issue H brings the real one, and F the
/// editing tools and the note card.
struct RollScreen: View {
    let model: MobileModel

    var body: some View {
        VStack(spacing: 0) {
            TransportPlaceholder(model: model)

            TimelineView(model: model)
                .overlay {
                    if model.source == nil {
                        ContentUnavailableView {
                            Label {
                                Text("No take yet", comment: "Roll screen: there is no audio in the project")
                            } icon: {
                                Image(systemName: "pianokeys")
                            }
                        } description: {
                            Text("Record or import a take on the Transcribe screen.",
                                 comment: "Roll screen: where a take comes from")
                        }
                        .foregroundStyle(.secondary)
                    }
                }
                .accessibilityIdentifier("timeline")
        }
        .background(Color(cgColor: TimelinePalette.bgRoot))
    }
}

/// Play/Pause and where the playhead is, polled from the engine while the screen shows.
private struct TransportPlaceholder: View {
    let model: MobileModel

    var body: some View {
        SwiftUI.TimelineView(.periodic(from: .now, by: 1.0 / 15)) { _ in
            let playing = model.isPlaying

            HStack(spacing: 14) {
                Button { model.togglePlay() } label: {
                    Image(systemName: playing ? "pause.fill" : "play.fill")
                        .font(.title2)
                        .frame(width: 44, height: 44)
                }
                .disabled(!model.canPlay)
                .accessibilityLabel(playing ? Text("Pause", comment: "Transport: pause playback")
                                            : Text("Play", comment: "Transport: start playback"))
                .accessibilityIdentifier("play")

                Text(verbatim: "\(TimeFormat.transport(model.engine.playheadSeconds)) / \(TimeFormat.transport(model.duration))")
                    .font(.system(.subheadline, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .accessibilityLabel(Text("Position", comment: "Transport: the playhead's time"))

                Spacer()
            }
            .padding(.horizontal, 12)
        }
        .frame(height: 52)
        .background(.bar)
    }
}

/// The Score tab until sub-issue G.
struct ScorePlaceholder: View {
    var body: some View {
        ContentUnavailableView {
            Label {
                Text("Score", comment: "Tab: the score")
            } icon: {
                Image(systemName: "music.note.list")
            }
        } description: {
            Text("The score view is coming.", comment: "Score tab placeholder")
        }
    }
}
