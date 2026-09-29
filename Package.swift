// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "stalker",
    platforms: [.macOS(.v14)],
    targets: [
        .target(
            name: "StalkerCore",
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        .target(name: "StalkerMac", dependencies: ["StalkerCore"]),
        .executableTarget(name: "stalker", dependencies: ["StalkerCore", "StalkerMac"]),
        .executableTarget(name: "stalker-tests", dependencies: ["StalkerCore", "StalkerMac"]),
    ]
)
