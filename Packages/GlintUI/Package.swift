// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "GlintUI",
    platforms: [.macOS("15.0")],
    products: [
        .library(name: "GlintUI", targets: ["GlintUI"])
    ],
    dependencies: [
        .package(path: "../GlintCore"),
        .package(path: "../GlintPlugins"),
    ],
    targets: [
        .target(
            name: "GlintUI",
            dependencies: [
                .product(name: "GlintCore", package: "GlintCore"),
                .product(name: "GlintPlugins", package: "GlintPlugins"),
            ]
        ),
        .testTarget(
            name: "GlintUITests",
            dependencies: ["GlintUI"]
        ),
    ],
    swiftLanguageModes: [.v6]
)
