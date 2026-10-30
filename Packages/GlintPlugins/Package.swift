// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "GlintPlugins",
    platforms: [.macOS("15.0")],
    products: [
        .library(name: "GlintPlugins", targets: ["GlintPlugins"]),
        .executable(name: "glint-plugin-probe", targets: ["GlintPluginProbe"]),
    ],
    dependencies: [
        .package(path: "../GlintCore"),
        .package(path: "../GlintDictionary"),
    ],
    targets: [
        .target(
            name: "GlintPlugins",
            dependencies: [
                .product(name: "GlintCore", package: "GlintCore"),
                .product(
                    name: "GlintDictionary",
                    package: "GlintDictionary"
                ),
            ],
            linkerSettings: [
                .linkedLibrary("z")
            ]
        ),
        .executableTarget(
            name: "GlintPluginProbe",
            dependencies: ["GlintPlugins"]
        ),
        .testTarget(
            name: "GlintPluginsTests",
            dependencies: ["GlintPlugins"]
        ),
    ],
    swiftLanguageModes: [.v6]
)
