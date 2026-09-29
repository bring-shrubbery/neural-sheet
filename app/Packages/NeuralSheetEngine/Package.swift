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
            swiftSettings: [
                .swiftLanguageMode(.v5), .unsafeFlags(["-Xcc", "-DACCELERATE_NEW_LAPACK"]),
                // The engine is compute code, and the C++ it replaces was always compiled
                // Release whatever the app's configuration was (Scripts/build-engine.sh), so a
                // Debug build optimises it too. At -Onone the Float16 SIMD GEMV of a decode
                // step runs twenty times slower, which would make a Debug app unusable and the
                // oracle suites a quarter of an hour of `swift test`.
                .unsafeFlags(["-O"], .when(configuration: .debug)),
            ]),
        .executableTarget(name: "engine-bench", dependencies: ["NeuralSheetEngine"], swiftSettings: [.swiftLanguageMode(.v5)]),
        .testTarget(
            name: "NeuralSheetEngineTests", dependencies: ["NeuralSheetEngine"],
            resources: [.copy("Fixtures")], swiftSettings: [.swiftLanguageMode(.v5)]),
    ])
