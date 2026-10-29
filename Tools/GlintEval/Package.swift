// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "GlintEval",
    platforms: [.macOS("26.0")],
    dependencies: [
        .package(path: "../../Packages/GlintCore"),
        .package(path: "../../Packages/GlintDictionary"),
        .package(path: "../../Packages/GlintInference"),
        .package(path: "../../Packages/GlintMac"),
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
            name: "TranslationCompare",
            dependencies: [
                .product(name: "GlintCore", package: "GlintCore"),
                .product(name: "GlintInference", package: "GlintInference"),
            ]
        ),
        .executableTarget(
            name: "TranslationModeCompare",
            dependencies: [
                .product(name: "GlintCore", package: "GlintCore"),
                .product(name: "GlintDictionary", package: "GlintDictionary"),
                .product(name: "GlintInference", package: "GlintInference"),
            ]
        ),
        .executableTarget(
            name: "ContextAXProbe"
        ),
        .executableTarget(
            name: "CandidateAXProbe"
        ),
        .executableTarget(
            name: "WeTypeAXProbe"
        ),
        .executableTarget(
            name: "CandidateProfileProbe",
            dependencies: [
                .product(name: "GlintMac", package: "GlintMac")
            ]
        ),
        .executableTarget(
            name: "SelectedTextItemCacheProbe",
            dependencies: [
                .product(name: "GlintMac", package: "GlintMac")
            ]
        ),
    ],
    swiftLanguageModes: [.v6]
)
