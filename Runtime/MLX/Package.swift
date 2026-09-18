// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "PomvoxCleanupMLX",
    platforms: [.macOS(.v14)],
    products: [.library(name: "PomvoxCleanupMLX", targets: ["PomvoxCleanupMLX"])],
    dependencies: [
        .package(name: "PomvoxCleanup", path: "../.."),
        .package(url: "https://github.com/ml-explore/mlx-swift", exact: "0.31.4"),
        .package(url: "https://github.com/ml-explore/mlx-swift-lm.git", exact: "3.31.4"),
        .package(url: "https://github.com/DePasqualeOrg/swift-tokenizers-mlx.git", exact: "0.3.0"),
        .package(url: "https://github.com/DePasqualeOrg/swift-tokenizers.git", exact: "0.5.0"),
    ],
    targets: [
        .target(name: "PomvoxCleanupMLX", dependencies: [
            .product(name: "PomvoxCleanup", package: "PomvoxCleanup"),
            .product(name: "MLXLLM", package: "mlx-swift-lm"),
            .product(name: "MLXLMCommon", package: "mlx-swift-lm"),
            .product(name: "MLXLMTokenizers", package: "swift-tokenizers-mlx"),
        ]),
        .testTarget(name: "PomvoxCleanupMLXTests", dependencies: ["PomvoxCleanupMLX"]),
    ],
    swiftLanguageModes: [.v5]
)
