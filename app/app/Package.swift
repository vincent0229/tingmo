// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "E1Recorder",
    platforms: [.macOS(.v15)],
    targets: [
        .executableTarget(
            name: "E1Recorder",
            path: "Sources/E1Recorder",
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        .testTarget(
            name: "E1RecorderTests",
            dependencies: ["E1Recorder"],
            path: "Tests/E1RecorderTests"
        ),
    ],
    swiftLanguageModes: [.v5]
)
