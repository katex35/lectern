// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "Lectern",
    defaultLocalization: "en",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Lectern", targets: ["Lectern"]),
        .executable(name: "lectern-recorder", targets: ["lectern-recorder"]),
        .library(name: "LecternCore", targets: ["LecternCore"]),
    ],
    targets: [
        .target(
            name: "LecternCore",
            path: "Sources/LecternCore"
        ),
        // Records in its own process: if the app crashes or quits, the lecture keeps recording.
        .executableTarget(
            name: "lectern-recorder",
            dependencies: ["LecternCore"],
            path: "Sources/lectern-recorder"
        ),
        .executableTarget(
            name: "Lectern",
            dependencies: ["LecternCore"],
            path: "Sources/Lectern",
            resources: [.process("Resources")]
        ),
        .testTarget(
            name: "LecternCoreTests",
            dependencies: ["LecternCore", "lectern-recorder"],
            path: "Tests/LecternCoreTests"
        ),
    ]
)
