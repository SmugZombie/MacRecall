// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "RecallCore",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "RecallCore", targets: ["RecallCore"]),
    ],
    targets: [
        .target(
            name: "RecallCore",
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        .testTarget(name: "RecallCoreTests", dependencies: ["RecallCore"]),
    ],
    swiftLanguageModes: [.v5]
)
