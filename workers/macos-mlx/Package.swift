// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AcpmWorkerMLX",
    platforms: [
        .macOS(.v15),
    ],
    products: [
        .library(name: "WorkerCore", targets: ["WorkerCore"]),
        .library(name: "EngineLLM", targets: ["EngineLLM"]),
        .library(name: "EngineASR", targets: ["EngineASR"]),
        .library(name: "EngineTTS", targets: ["EngineTTS"]),
        .executable(name: "acpm-worker-mlx", targets: ["AcpmWorkerMLX"]),
    ],
    dependencies: [
        // Phase 0: uncomment and build with full Xcode 16+ so mlx.metallib is compiled.
        // .package(url: "https://github.com/ml-explore/mlx-swift", from: "0.21.0"),
        // .package(url: "https://github.com/ml-explore/mlx-swift-lm", from: "0.1.0"),
        // .package(url: "https://github.com/Blaizzy/mlx-audio-swift", branch: "main"),
    ],
    targets: [
        .target(
            name: "WorkerCore"
        ),
        .target(
            name: "EngineLLM",
            dependencies: ["WorkerCore"]
        ),
        .target(
            name: "EngineASR",
            dependencies: ["WorkerCore"]
        ),
        .target(
            name: "EngineTTS",
            dependencies: ["WorkerCore"]
        ),
        .executableTarget(
            name: "AcpmWorkerMLX",
            dependencies: [
                "WorkerCore",
                "EngineLLM",
                "EngineASR",
                "EngineTTS",
            ]
        ),
        .testTarget(
            name: "WorkerCoreTests",
            dependencies: ["WorkerCore", "EngineLLM", "EngineASR", "EngineTTS"]
        ),
    ]
)
