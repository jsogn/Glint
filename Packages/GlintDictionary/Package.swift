// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "GlintDictionary",
    platforms: [.macOS("15.0")],
    products: [
        .library(name: "GlintDictionary", targets: ["GlintDictionary"]),
        .executable(
            name: "glint-dictionary-builder",
            targets: ["GlintDictionaryBuilder"]
        ),
    ],
    dependencies: [
        .package(path: "../GlintCore")
    ],
    targets: [
        .target(
            name: "GlintDictionary",
            dependencies: [.product(name: "GlintCore", package: "GlintCore")],
            linkerSettings: [
                .linkedLibrary("sqlite3"),
                .linkedLibrary("z"),
            ]
        ),
        .executableTarget(
            name: "GlintDictionaryBuilder",
            dependencies: ["GlintDictionary"]
        ),
        .testTarget(
            name: "GlintDictionaryTests",
            dependencies: ["GlintDictionary", "GlintCore"]
        ),
    ],
    swiftLanguageModes: [.v6]
)
