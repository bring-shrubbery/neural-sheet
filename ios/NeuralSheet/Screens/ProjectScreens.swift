import NeuralSheetCore
import SwiftUI

/// A project's screens (iOS app design §2): tabs on iPhone -- Transcribe, Roll, Score, Settings --
/// and on iPad a split view whose sidebar lists the screens and the take's instrument strips
/// (sub-issue H) beside the chosen screen, the roll first. Over every screen: the model's
/// message box, and the export sheet whichever screen's Export menu opened it (sub-issue I).
struct ProjectScreens: View {
    let model: MobileModel

    @Environment(\.horizontalSizeClass) private var sizeClass

    var body: some View {
        Group {
            if sizeClass == .regular {
                ProjectSplitView(model: model)
            } else {
                ProjectTabs(model: model)
            }
        }
        .exportPresentation(model)
        .alert(item: Binding(get: { model.alert }, set: { model.alert = $0 })) { alert in
            Alert(title: Text(alert.title), message: alert.message.isEmpty ? nil : Text(alert.message))
        }
    }
}

/// The screens a project has.
enum ProjectScreen: Hashable, CaseIterable {
    case transcribe, roll, score, settings

    var title: Text {
        switch self {
        case .transcribe: Text("Transcribe", comment: "Tab: the Transcribe screen")
        case .roll: Text("Roll", comment: "Tab: the piano roll")
        case .score: Text("Score", comment: "Tab: the score")
        case .settings: Text("Settings", comment: "Tab: the settings")
        }
    }

    var systemImage: String {
        switch self {
        case .transcribe: "waveform"
        case .roll: "pianokeys"
        case .score: "music.note.list"
        case .settings: "gearshape"
        }
    }

    @ViewBuilder
    func view(_ model: MobileModel) -> some View {
        switch self {
        case .transcribe: TranscribeScreen(model: model)
        case .roll: RollScreen(model: model)
        case .score: ScoreScreen(model: model)
        case .settings: SettingsScreen()
        }
    }
}

/// iPhone: one tab per screen.
private struct ProjectTabs: View {
    let model: MobileModel

    @State private var selection: ProjectScreen = .transcribe

    var body: some View {
        TabView(selection: $selection) {
            ForEach(ProjectScreen.allCases, id: \.self) { screen in
                Tab(value: screen) {
                    screen.view(model)
                } label: {
                    Label { screen.title } icon: { Image(systemName: screen.systemImage) }
                }
            }
        }
    }
}

/// iPad: the screens and the instrument strips in the sidebar, the chosen screen beside it.
/// Tapping a strip's name singles it out on the roll, as a strip click does on the Mac.
private struct ProjectSplitView: View {
    let model: MobileModel

    @State private var selection: ProjectScreen? = .roll

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                Section {
                    ForEach(ProjectScreen.allCases, id: \.self) { screen in
                        Label { screen.title } icon: { Image(systemName: screen.systemImage) }
                            .tag(screen)
                    }
                }

                InstrumentStripsSection(model: model)
            }
            .navigationTitle(Text(verbatim: "NeuralSheet"))
        } detail: {
            (selection ?? .roll).view(model)
        }
    }
}
