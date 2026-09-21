import UniformTypeIdentifiers

extension UTType {
    /// The `.neuralsheet` package, as `app/Info.plist` exports it.
    static let neuralSheetProject = UTType(exportedAs: "com.quassum.neuralsheet.project", conformingTo: .package)
}
