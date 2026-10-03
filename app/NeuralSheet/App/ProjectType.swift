import UniformTypeIdentifiers

extension UTType {
    /// The `.neuralsheet` package, as `app/Info.plist` exports it. Nonisolated so the iOS
    /// document's `readableContentTypes`, which SwiftUI reads off the main actor, can name it; the
    /// iOS target compiles this file by path, so both apps declare the one type.
    nonisolated static let neuralSheetProject = UTType(exportedAs: "com.quassum.neuralsheet.project", conformingTo: .package)
}
