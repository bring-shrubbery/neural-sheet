import NeuralSheetCore
import SwiftUI

/// The score screen (iOS app design §2, sub-issue G): the touch score under the placeholder
/// transport, with the Sheet button that opens the title block and the layout. Read-only, as the
/// design says: a tap seeks, a tap on a part's name opens its display sheet, a pinch scales.
struct ScoreScreen: View {
    let model: MobileModel

    @State private var part: PartSelection?
    @State private var isSheetShown = false

    var body: some View {
        VStack(spacing: 0) {
            TransportPlaceholder(model: model) {
                Button {
                    isSheetShown = true
                } label: {
                    Image(systemName: "doc.richtext")
                        .font(.title3)
                        .frame(width: 44, height: 44)
                }
                .accessibilityLabel(Text("Sheet", comment: "Score sheet: its title"))
                .accessibilityIdentifier("sheet")
            }

            ScoreView(model: model) { program in
                part = PartSelection(program: program)
            }
            .overlay {
                if model.document == nil, model.streamedNotes.isEmpty {
                    ContentUnavailableView {
                        Label {
                            Text("No notes yet", comment: "Score screen: there is no transcription in the project")
                        } icon: {
                            Image(systemName: "music.note.list")
                        }
                    } description: {
                        Text("Transcribe a take on the Transcribe screen.",
                             comment: "Score screen: where the notes come from")
                    }
                    .foregroundStyle(.secondary)
                }
            }
        }
        .background(Color(cgColor: ScoreRenderer.Style.screen.paper))
        .sheet(item: $part) { selection in
            PartDisplaySheet(model: model, program: selection.program)
                .presentationDetents([.medium, .large])
        }
        .sheet(isPresented: $isSheetShown) {
            ScoreSheetForm(model: model)
                .presentationDetents([.medium, .large])
        }
    }
}

/// The part a tap on its name chose, for the sheet.
private struct PartSelection: Identifiable {
    var program: Int
    var id: Int { program }
}

/// The touch score for SwiftUI. UIKit underneath, as the timeline is: it scrolls, scales and
/// moves its cursor every frame. It watches the model itself; SwiftUI hands it its frame and what
/// a tap on a part's name does.
private struct ScoreView: UIViewRepresentable {
    let model: MobileModel
    var onPartName: (Int) -> Void

    func makeUIView(context: Context) -> ScoreTouchView {
        let view = ScoreTouchView(model: model)
        view.onPartName = onPartName
        return view
    }

    func updateUIView(_ view: ScoreTouchView, context: Context) {
        view.onPartName = onPartName
    }
}
