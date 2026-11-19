// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "TyphonCore",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "TyphonCore", targets: ["TyphonCore"]),
        .executable(name: "typhon-bench", targets: ["typhon-bench"]),
    ],
    dependencies: [
        .package(url: "https://github.com/ml-explore/mlx-swift-lm", exact: "3.33.0"),
        .package(url: "https://github.com/huggingface/swift-transformers", from: "1.3.0"),
    ],
    targets: [
        .target(
            name: "TyphonCore",
            dependencies: [
                .product(name: "MLXLLM", package: "mlx-swift-lm"),
                .product(name: "MLXLMCommon", package: "mlx-swift-lm"),
                .product(name: "Tokenizers", package: "swift-transformers"),
            ]),
        .executableTarget(name: "typhon-bench", dependencies: ["TyphonCore"]),
    ]
)
