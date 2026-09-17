// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "NeuralSheetCore",
    platforms: [.macOS(.v26)],
    products: [.library(name: "NeuralSheetCore", targets: ["NeuralSheetCore"])],
    targets: [
        .target(name: "NeuralSheetCore", swiftSettings: [.swiftLanguageMode(.v5)]),
        .testTarget(name: "NeuralSheetCoreTests", dependencies: ["NeuralSheetCore"], swiftSettings: [.swiftLanguageMode(.v5)]),
    ])
