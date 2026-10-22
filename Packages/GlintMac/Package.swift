// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "GlintMac",
    platforms: [.macOS("26.0")],
    products: [
        .library(name: "GlintMac", targets: ["GlintMac"]),
    ],
    dependencies: [
        .package(path: "../GlintCore"),
    ],
    targets: [
        .target(
            name: "GlintMac",
            dependencies: [
                .product(name: "GlintCore", package: "GlintCore"),
            ],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("ApplicationServices"),
                .linkedFramework("Carbon"),
            ]
        ),
        .testTarget(
            name: "GlintMacTests",
            dependencies: ["GlintMac"]
        ),
    ],
    swiftLanguageModes: [.v6]
)
