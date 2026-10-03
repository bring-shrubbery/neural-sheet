import NeuralSheetCore
import SwiftUI

/// A project's screens (iOS app design §2): tabs on iPhone -- Transcribe, Roll, Score, Settings --
/// and on iPad a split view whose sidebar lists the screens and the take's instruments (their
/// strips come with sub-issue H) beside the chosen screen, the roll first.
struct ProjectScreens: View {
    let model: MobileModel

    @Environment(\.horizontalSizeClass) private var sizeClass

    var body: some View {
        if sizeClass == .regular {
            ProjectSplitView(model: model)
        } else {
            ProjectTabs(model: model)
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

/// iPad: the screens and the instruments in the sidebar, the chosen screen beside it. Tapping an
/// instrument singles it out on the roll, as a strip click does on the Mac; again lets it go.
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

                Section {
                    ForEach(instruments, id: \.program) { row in
                        instrumentRow(row)
                    }
                } header: {
                    Text("Instruments", comment: "iPad sidebar: the take's instruments")
                }
            }
            .navigationTitle(Text(verbatim: "NeuralSheet"))
        } detail: {
            (selection ?? .roll).view(model)
        }
    }

    private struct InstrumentRow {
        var program: Int
        var name: String
        var colour: NeuralSheetCore.RGBA
        var count: Int
    }

    /// The instruments the notes use, in program order, with their note counts.
    private var instruments: [InstrumentRow] {
        let counts = Dictionary(grouping: model.timelineNotes, by: \.note.program).mapValues(\.count)

        return counts.keys.sorted().map { program in
            let info = Instruments.info(forProgram: program)

            return InstrumentRow(program: program, name: info.localizedName, colour: info.colour, count: counts[program] ?? 0)
        }
    }

    private func instrumentRow(_ row: InstrumentRow) -> some View {
        let highlighted = model.highlightedProgram == row.program

        return Button {
            model.highlightedProgram = highlighted ? nil : row.program
        } label: {
            HStack(spacing: 10) {
                Circle()
                    .fill(Color(.sRGB, red: row.colour.r, green: row.colour.g, blue: row.colour.b, opacity: row.colour.a))
                    .frame(width: 12, height: 12)
                Text(row.name)
                Spacer()
                Text(row.count, format: .number)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            .fontWeight(highlighted ? .semibold : .regular)
        }
        .accessibilityAddTraits(highlighted ? .isSelected : [])
    }
}
