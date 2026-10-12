// swift-tools-version: 6.0
import PackageDescription

// Optional Apple Silicon diarization runtime over FluidAudio's offline pyannote
// community-1 pipeline. Kept out of the root package so contract and transport
// users do not acquire Core ML model dependencies. FluidAudio is pinned exactly:
// the Pomvox app constrains it to 0.15.x, and the pack manifest names this release.
let package = Package(
    name: "PomvoxDiarizationFluid",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        .library(name: "PomvoxDiarizationFluid", targets: ["PomvoxDiarizationFluid"]),
        .executable(name: "speaker-notes-example", targets: ["SpeakerNotesExample"]),
    ],
    dependencies: [
        .package(name: "PomvoxCleanup", path: "../.."),
        .package(url: "https://github.com/FluidInference/FluidAudio.git", exact: "0.15.5"),
    ],
    targets: [
        .target(name: "PomvoxDiarizationFluid", dependencies: [
            .product(name: "PomvoxDiarization", package: "PomvoxCleanup"),
            .product(name: "FluidAudio", package: "FluidAudio"),
        ]),
        // Host stand-in only: the SDK owns no STT. The example runs Parakeet through
        // FluidAudio to obtain word timings, as the Pomvox app does on its side.
        .executableTarget(name: "SpeakerNotesExample", dependencies: [
            "PomvoxDiarizationFluid",
            .product(name: "PomvoxNotes", package: "PomvoxCleanup"),
            .product(name: "FluidAudio", package: "FluidAudio"),
        ], path: "Examples/SpeakerNotes"),
        .testTarget(name: "PomvoxDiarizationFluidTests", dependencies: ["PomvoxDiarizationFluid"]),
    ],
    swiftLanguageModes: [.v5]
)
