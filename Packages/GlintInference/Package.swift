// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "GlintInference",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "GlintInference", targets: ["GlintInference"]),
        .executable(name: "glint-mlx-probe", targets: ["GlintMLXProbe"]),
    ],
    dependencies: [
        .package(path: "../GlintCore"),
        .package(
            url: "https://github.com/ml-explore/mlx-swift-lm.git",
            exact: "3.32.3"
        ),
        .package(
            url: "https://github.com/huggingface/swift-transformers.git",
            exact: "1.3.5"
        ),
    ],
    targets: [
        .target(
            name: "GlintInference",
            dependencies: [
                .product(name: "GlintCore", package: "GlintCore"),
                .product(name: "MLXLLM", package: "mlx-swift-lm"),
                .product(name: "MLXLMCommon", package: "mlx-swift-lm"),
                .product(name: "Tokenizers", package: "swift-transformers"),
            ]
        ),
        .executableTarget(
            name: "GlintMLXProbe",
            dependencies: [
                "GlintInference",
                .product(name: "GlintCore", package: "GlintCore"),
            ]
        ),
        .testTarget(
            name: "GlintInferenceTests",
            dependencies: ["GlintInference", "GlintCore"]
        ),
    ],
    swiftLanguageModes: [.v6]
)
