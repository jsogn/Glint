// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "GlintEval",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(path: "../../Packages/GlintCore"),
        .package(path: "../../Packages/GlintDictionary"),
        .package(path: "../../Packages/GlintInference"),
    ],
    targets: [
        .executableTarget(
            name: "GlintEval",
            dependencies: [
                .product(name: "GlintCore", package: "GlintCore"),
                .product(name: "GlintDictionary", package: "GlintDictionary"),
                .product(name: "GlintInference", package: "GlintInference"),
            ]
        ),
        .executableTarget(
            name: "DictionaryChoices",
            dependencies: [
                .product(name: "GlintCore", package: "GlintCore"),
                .product(name: "GlintDictionary", package: "GlintDictionary"),
            ]
        ),
        .executableTarget(
            name: "ContextAXProbe"
        ),
    ],
    swiftLanguageModes: [.v6]
)
