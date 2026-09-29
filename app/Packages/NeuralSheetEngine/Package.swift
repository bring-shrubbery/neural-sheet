// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "NeuralSheetEngine",
    platforms: [.macOS(.v26), .iOS(.v26)],
    products: [
        .library(name: "NeuralSheetEngine", targets: ["NeuralSheetEngine"]),
        .executable(name: "engine-bench", targets: ["engine-bench"]),
    ],
    targets: [
        // Accelerate's legacy CBLAS declarations are deprecated as of macOS 13.3, and
        // warnings are errors here, so the clang importer needs the macro that swaps in
        // the current ones. There is no non-"unsafe" spelling for a -Xcc flag; the app
        // references this package by path, where SwiftPM allows them.
        .target(
            name: "NeuralSheetEngine",
            swiftSettings: [.swiftLanguageMode(.v5), .unsafeFlags(["-Xcc", "-DACCELERATE_NEW_LAPACK"])]),
        .executableTarget(name: "engine-bench", dependencies: ["NeuralSheetEngine"], swiftSettings: [.swiftLanguageMode(.v5)]),
        .testTarget(
            name: "NeuralSheetEngineTests", dependencies: ["NeuralSheetEngine"],
            resources: [.copy("Fixtures")], swiftSettings: [.swiftLanguageMode(.v5)]),
    ])
