// swift-tools-version: 6.0
import PackageDescription
let package = Package(name: "CleanupConsumer", platforms: [.macOS(.v14)],
    dependencies: [.package(name: "PomvoxCleanupMLX", path: "../../Runtime/MLX")],
    targets: [.executableTarget(name: "Consumer", dependencies: [
        .product(name: "PomvoxCleanupMLX", package: "PomvoxCleanupMLX")
    ])])
