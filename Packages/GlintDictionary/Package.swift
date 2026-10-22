// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "GlintDictionary",
    platforms: [.macOS("26.0")],
    products: [
        .library(name: "GlintDictionary", targets: ["GlintDictionary"]),
    ],
    dependencies: [
        .package(path: "../GlintCore"),
    ],
    targets: [
        .target(
            name: "GlintDictionary",
            dependencies: [.product(name: "GlintCore", package: "GlintCore")],
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        .testTarget(
            name: "GlintDictionaryTests",
            dependencies: ["GlintDictionary", "GlintCore"]
        ),
    ],
    swiftLanguageModes: [.v6]
)
