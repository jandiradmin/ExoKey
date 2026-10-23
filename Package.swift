// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "ExoKey",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "ExoKey",
            path: "Sources/ExoKey",
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
    ]
)
