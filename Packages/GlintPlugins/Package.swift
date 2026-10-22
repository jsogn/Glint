// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "GlintPlugins",
    platforms: [.macOS("26.0")],
    products: [
        .library(name: "GlintPlugins", targets: ["GlintPlugins"]),
        .executable(name: "glint-plugin-probe", targets: ["GlintPluginProbe"]),
    ],
    dependencies: [
        .package(path: "../GlintCore"),
    ],
    targets: [
        .target(
            name: "GlintPlugins",
            dependencies: [.product(name: "GlintCore", package: "GlintCore")]
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
