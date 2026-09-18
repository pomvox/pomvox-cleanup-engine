// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "PomvoxCleanup",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "PomvoxCleanup", targets: ["PomvoxCleanup"]),
        .library(name: "PomvoxCleanupCloud", targets: ["PomvoxCleanupCloud"]),
    ],
    targets: [
        .target(name: "CleanupCore"),
        .target(name: "CleanupPacks", dependencies: ["CleanupCore"]),
        .target(name: "PomvoxCleanup", dependencies: ["CleanupCore", "CleanupPacks"]),
        .target(name: "PomvoxCleanupCloud", dependencies: ["CleanupCore"]),
        .target(name: "PomvoxAdapterExample", dependencies: ["PomvoxCleanup"], path: "Examples/PomvoxAdapter"),
        .testTarget(name: "CleanupCoreTests", dependencies: ["CleanupCore", "PomvoxCleanup", "PomvoxAdapterExample"]),
        .testTarget(name: "CleanupPacksTests", dependencies: ["CleanupPacks", "PomvoxCleanup"]),
        .testTarget(name: "PomvoxCleanupCloudTests", dependencies: ["PomvoxCleanupCloud"], exclude: ["Fixtures"]),
    ],
    swiftLanguageModes: [.v6]
)
