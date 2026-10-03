// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "NeuralSheetCore",
    platforms: [.macOS(.v26), .iOS(.v26)],
    products: [.library(name: "NeuralSheetCore", targets: ["NeuralSheetCore"])],
    targets: [
        // Optimised in Debug as well: the resampler and the tempo and key estimators are
        // sample-by-sample loops, and at -Onone the resampling of a five-minute song takes about
        // two minutes on the main thread, where a Debug build shows the spinning cursor for as
        // long. In Release the same work takes under half a second. The engine package makes the
        // same choice for the same reason.
        .target(
            name: "NeuralSheetCore",
            swiftSettings: [.swiftLanguageMode(.v5), .unsafeFlags(["-O"], .when(configuration: .debug))]),
        .testTarget(name: "NeuralSheetCoreTests", dependencies: ["NeuralSheetCore"], swiftSettings: [.swiftLanguageMode(.v5)]),
    ])
