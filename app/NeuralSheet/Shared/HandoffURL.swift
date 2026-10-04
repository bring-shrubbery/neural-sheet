import Foundation
import NeuralSheetCore

/// *Open in NeuralSheet* (Audio Unit design §2): the URL the Audio Unit opens to hand a project
/// to the app, `neuralsheet://open?path=<percent-encoded package path>`, and the app's check of
/// it. Compiled by the Mac app, which registers the scheme and validates, and by the plugin, which
/// builds the URL, so the two cannot disagree on its shape.
///
/// Any app can open a `neuralsheet:` URL, so the path is trusted only when it names exactly
/// `<handoff>/<uuid>/<name>.neuralsheet` -- after `..` and symbolic links are resolved -- inside
/// the App Group container's handoff folder, where only the plugin and the app can write.
nonisolated enum HandoffURL {
    static let scheme = "neuralsheet"
    static let openHost = "open"
    static let pathItem = "path"

    /// What a path's characters may be left as in the query: everything else is percent-encoded,
    /// `&`, `=`, `+`, `#` and `%` included, so any file name survives.
    private static let unescaped = CharacterSet(
        charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~/")

    /// The URL that asks the app to open the package at `package`.
    static func url(forPackage package: URL) -> URL? {
        guard let encoded = package.path.addingPercentEncoding(withAllowedCharacters: unescaped) else { return nil }

        var components = URLComponents()
        components.scheme = scheme
        components.host = openHost
        components.percentEncodedQuery = "\(pathItem)=\(encoded)"
        return components.url
    }

    /// The package `url` names when it is an open URL for a package directly inside a
    /// `<uuid>` folder of `handoff`, else nil. Nothing is read from the disk but the symbolic
    /// links on the way.
    static func package(from url: URL, handoff: URL) -> URL? {
        guard url.scheme?.lowercased() == scheme, url.host?.lowercased() == openHost,
            let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems
        else { return nil }

        let paths = items.filter { $0.name == pathItem }

        guard paths.count == 1, let path = paths[0].value, path.hasPrefix("/") else { return nil }

        let package = URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath()
        let root = handoff.standardizedFileURL.resolvingSymlinksInPath().pathComponents
        let components = package.pathComponents

        guard components.count == root.count + 2, Array(components.prefix(root.count)) == root,
            UUID(uuidString: components[root.count]) != nil,
            package.pathExtension.lowercased() == ProjectPackage.pathExtension,
            !package.deletingPathExtension().lastPathComponent.isEmpty
        else { return nil }

        return package
    }
}
