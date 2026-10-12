// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "PomvoxCleanup",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        .library(name: "PomvoxCleanup", targets: ["PomvoxCleanup"]),
        .library(name: "PomvoxCleanupCloud", targets: ["PomvoxCleanupCloud"]),
        .library(name: "PomvoxNotes", targets: ["PomvoxNotes"]),
        .library(name: "PomvoxDiarization", targets: ["PomvoxDiarization"]),
    ],
    targets: [
        .target(name: "CleanupCore"),
        .target(name: "CleanupPacks", dependencies: ["CleanupCore"]),
        .target(name: "CleanupNotes", dependencies: ["CleanupCore"]),
        .target(name: "CleanupDiarization", dependencies: ["CleanupCore", "CleanupPacks"]),
        .target(name: "PomvoxCleanup", dependencies: ["CleanupCore", "CleanupPacks"]),
        .target(name: "PomvoxNotes", dependencies: ["CleanupNotes"]),
        .target(name: "PomvoxDiarization", dependencies: ["CleanupDiarization"]),
        .target(name: "PomvoxCleanupCloud", dependencies: ["CleanupCore", "CleanupDiarization", "CleanupNotes"]),
        .target(name: "PomvoxAdapterExample", dependencies: ["PomvoxCleanup"], path: "Examples/PomvoxAdapter"),
        .testTarget(name: "CleanupCoreTests", dependencies: ["CleanupCore", "PomvoxCleanup", "PomvoxAdapterExample"]),
        .testTarget(name: "CleanupPacksTests", dependencies: ["CleanupPacks", "PomvoxCleanup"]),
        .testTarget(name: "CleanupNotesTests", dependencies: ["CleanupNotes", "PomvoxNotes", "PomvoxDiarization"]),
        .testTarget(name: "CleanupDiarizationTests", dependencies: ["CleanupDiarization"]),
        .testTarget(name: "PomvoxCleanupCloudTests", dependencies: ["PomvoxCleanupCloud"], exclude: ["Fixtures"]),
    ],
    swiftLanguageModes: [.v6]
)
