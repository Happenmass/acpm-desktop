// swift-tools-version: 6.3
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
        .package(url: "https://github.com/ml-explore/mlx-swift.git", exact: "0.33.0"),
        .package(url: "https://github.com/ml-explore/mlx-swift-lm.git", exact: "3.33.0", traits: []),
        .package(url: "https://github.com/Blaizzy/mlx-audio-swift.git", branch: "main"),
        .package(url: "https://github.com/huggingface/swift-transformers.git", .upToNextMajor(from: "1.4.0")),
    ],
    targets: [
        .target(
            name: "WorkerCore"
        ),
        .target(
            name: "EngineLLM",
            dependencies: [
                "WorkerCore",
                .product(name: "MLX", package: "mlx-swift"),
                .product(name: "MLXLLM", package: "mlx-swift-lm"),
                .product(name: "MLXLMCommon", package: "mlx-swift-lm"),
                .product(name: "Tokenizers", package: "swift-transformers"),
            ]
        ),
        .target(
            name: "EngineASR",
            dependencies: [
                "WorkerCore",
                .product(name: "MLX", package: "mlx-swift"),
                .product(name: "MLXAudioCore", package: "mlx-audio-swift"),
                .product(name: "MLXAudioSTT", package: "mlx-audio-swift"),
            ]
        ),
        .target(
            name: "EngineTTS",
            dependencies: [
                "WorkerCore",
                .product(name: "MLX", package: "mlx-swift"),
                .product(name: "MLXAudioCore", package: "mlx-audio-swift"),
                .product(name: "MLXAudioTTS", package: "mlx-audio-swift"),
            ]
        ),
        .executableTarget(
            name: "AcpmWorkerMLX",
            dependencies: [
                "WorkerCore",
                "EngineLLM",
                "EngineASR",
                "EngineTTS",
                .product(name: "MLX", package: "mlx-swift"),
            ]
        ),
        .testTarget(
            name: "WorkerCoreTests",
            dependencies: ["WorkerCore", "EngineLLM", "EngineASR", "EngineTTS"]
        ),
    ]
)
