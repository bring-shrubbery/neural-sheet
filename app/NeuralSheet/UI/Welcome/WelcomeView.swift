import AppKit
import SwiftUI

/// The window shown at launch and after the project window closes (projects design §6): the
/// app's icon, name and version with Create and Open on the left, the recent projects on the
/// right. In the app's own theme.
struct WelcomeView: View {
    let model: AppModel
    let recents: RecentProjects

    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow

    static let size = CGSize(width: 800, height: 460)
    private static let leftWidth: CGFloat = 440

    var body: some View {
        HStack(spacing: 0) {
            leftPane
                .frame(width: Self.leftWidth)
                .frame(maxHeight: .infinity)
                .background(Theme.bgPanel)

            Rectangle()
                .fill(Theme.divStrong)
                .frame(width: 1)

            RecentProjectsList(recents: recents) { url in
                open(url)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Theme.bgSidebar)
        }
        .frame(width: Self.size.width, height: Self.size.height)
        .background(Theme.bgRoot)
        .onAppear(perform: appear)
    }

    // MARK: - Left pane

    private var leftPane: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)

            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 128, height: 128)

            Text("NeuralSheet")
                .font(Fonts.sans(28, weight: 600))
                .foregroundStyle(Theme.textBright)
                .padding(.top, 14)

            Text("Version \(Self.version)")
                .font(Fonts.sans(12, weight: 400))
                .foregroundStyle(Theme.textMuted)
                .padding(.top, 4)

            VStack(alignment: .leading, spacing: 6) {
                WelcomeAction(title: "Create New Project", symbol: "plus.square") {
                    model.newProject()
                    showProject()
                }

                WelcomeAction(title: "Open Existing Project…", symbol: "folder") {
                    model.openProjectFromPanel()

                    if model.projectURL != nil {
                        showProject()
                    }
                }
            }
            .padding(.top, 36)

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 48)
    }

    private static var version: String {
        let info = Bundle.main.infoDictionary ?? [:]
        let short = info["CFBundleShortVersionString"] as? String ?? "?"
        let build = info["CFBundleVersion"] as? String ?? "?"

        return "\(short) (\(build))"
    }

    // MARK: - Actions

    /// The welcome window is only up while no project is open, so a URL that became the
    /// project is an open that succeeded; a failure shows its dialog (`appear` makes sure one is
    /// installed) and leaves it untitled.
    private func open(_ url: URL) {
        model.openProject(url: url)

        if model.projectURL == url {
            showProject()
        }
    }

    private func showProject() {
        openWindow(id: "main")
        dismissWindow(id: "welcome")
    }

    /// The model's window closures, and a file the Finder asked for before any window was up.
    private func appear() {
        // Before a project window has ever existed nothing can show a dialog; the nil-window
        // path of `Dialogs.present` is a deferred app-modal alert, which is right for a
        // failed open from here. The main view reinstalls its own, on its window, when it appears.
        if model.presentError == nil {
            Dialogs.install(on: model) { nil }
        }

        recents.refresh()

        model.showProjectWindow = { [openWindow, dismissWindow] in
            openWindow(id: "main")
            dismissWindow(id: "welcome")
        }
        model.showWelcomeWindow = { [openWindow] in
            openWindow(id: "welcome")
        }

        if model.pendingOpenURL != nil {
            showProject()
        }
    }
}

/// One of the two rows on the left: an SF Symbol and a label, lit on hover.
private struct WelcomeAction: View {
    let title: String
    let symbol: String
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: symbol)
                    .font(.system(size: 22, weight: .regular))
                    .foregroundStyle(Theme.accent)
                    .frame(width: 28)

                Text(title)
                    .font(Fonts.sans(14, weight: 500))
                    .foregroundStyle(Theme.textPrimary)

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .frame(height: 40)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(hovering ? Theme.bgControlActive : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}
