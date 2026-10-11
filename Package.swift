// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "PomvoxCleanup",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "PomvoxCleanup", targets: ["PomvoxCleanup"]),
        .library(name: "PomvoxCleanupCloud", targets: ["PomvoxCleanupCloud"]),
        .library(name: "PomvoxNotes", targets: ["CleanupNotes"]),
        .library(name: "PomvoxDiarization", targets: ["CleanupDiarization"]),
    ],
    targets: [
        .target(name: "CleanupCore"),
        .target(name: "CleanupPacks", dependencies: ["CleanupCore"]),
        .target(name: "CleanupNotes", dependencies: ["CleanupCore"]),
        .target(name: "CleanupDiarization", dependencies: ["CleanupCore", "CleanupPacks"]),
        .target(name: "PomvoxCleanup", dependencies: ["CleanupCore", "CleanupPacks"]),
        .target(name: "PomvoxCleanupCloud", dependencies: ["CleanupCore", "CleanupDiarization"]),
        .target(name: "PomvoxAdapterExample", dependencies: ["PomvoxCleanup"], path: "Examples/PomvoxAdapter"),
        .testTarget(name: "CleanupCoreTests", dependencies: ["CleanupCore", "PomvoxCleanup", "PomvoxAdapterExample"]),
        .testTarget(name: "CleanupPacksTests", dependencies: ["CleanupPacks", "PomvoxCleanup"]),
        .testTarget(name: "CleanupNotesTests", dependencies: ["CleanupNotes"]),
        .testTarget(name: "CleanupDiarizationTests", dependencies: ["CleanupDiarization"]),
        .testTarget(name: "PomvoxCleanupCloudTests", dependencies: ["PomvoxCleanupCloud"], exclude: ["Fixtures"]),
    ],
    swiftLanguageModes: [.v6]
)
