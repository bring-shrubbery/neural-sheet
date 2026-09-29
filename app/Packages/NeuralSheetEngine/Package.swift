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
        .target(name: "NeuralSheetEngine", swiftSettings: [.swiftLanguageMode(.v5)]),
        .executableTarget(name: "engine-bench", dependencies: ["NeuralSheetEngine"], swiftSettings: [.swiftLanguageMode(.v5)]),
        .testTarget(
            name: "NeuralSheetEngineTests", dependencies: ["NeuralSheetEngine"],
            resources: [.copy("Fixtures")], swiftSettings: [.swiftLanguageMode(.v5)]),
    ])
