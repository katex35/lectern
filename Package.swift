// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "Lectern",
    defaultLocalization: "en",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Lectern", targets: ["Lectern"]),
        .library(name: "LecternCore", targets: ["LecternCore"]),
    ],
    targets: [
        .target(
            name: "LecternCore",
            path: "Sources/LecternCore"
        ),
        .executableTarget(
            name: "Lectern",
            dependencies: ["LecternCore"],
            path: "Sources/Lectern",
            resources: [.process("Resources")]
        ),
        .testTarget(
            name: "LecternCoreTests",
            dependencies: ["LecternCore"],
            path: "Tests/LecternCoreTests"
        ),
    ]
)
