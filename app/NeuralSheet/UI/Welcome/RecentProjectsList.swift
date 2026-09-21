import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// The right pane of the welcome window: the recent projects, most recent first, with the
/// list's primary action (double-click, or Return on the selection) to open, and a right-click
/// for Show in Finder and Remove from Recents.
struct RecentProjectsList: View {
    let recents: RecentProjects
    let open: (URL) -> Void

    @State private var selection: URL?

    var body: some View {
        if recents.urls.isEmpty {
            Text("No Recent Projects")
                .font(Fonts.sans(13, weight: 400))
                .foregroundStyle(Theme.textFaint)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            List(recents.urls, id: \.self, selection: $selection) { url in
                row(url)
                    .tag(url)
                    .listRowBackground(Color.clear)
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .contextMenu(forSelectionType: URL.self) { urls in
                if let url = urls.first {
                    Button("Show in Finder") { recents.showInFinder(url) }
                    Button("Remove from Recents") {
                        if selection == url { selection = nil }
                        recents.remove(url)
                    }
                }
            } primaryAction: { urls in
                if let url = urls.first { open(url) }
            }
            .onKeyPress(.return) {
                guard let selection else { return .ignored }

                open(selection)
                return .handled
            }
        }
    }

    private func row(_ url: URL) -> some View {
        let exists = FileManager.default.fileExists(atPath: url.path)

        return HStack(spacing: 10) {
            Image(nsImage: NSWorkspace.shared.icon(for: .package))
                .resizable()
                .frame(width: 32, height: 32)

            VStack(alignment: .leading, spacing: 2) {
                Text(url.deletingPathExtension().lastPathComponent)
                    .font(Fonts.sans(13, weight: 500))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)

                Text(Self.abbreviated(url.deletingLastPathComponent().path))
                    .font(Fonts.sans(11, weight: 400))
                    .foregroundStyle(Theme.textFaint)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .padding(.vertical, 4)
        .opacity(exists ? 1 : 0.5)
    }

    /// `/Users/me/Music` → `~/Music`.
    private static func abbreviated(_ path: String) -> String {
        (path as NSString).abbreviatingWithTildeInPath
    }
}
