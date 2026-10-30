// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "GlintMac",
    platforms: [.macOS("15.0")],
    products: [
        .library(name: "GlintMac", targets: ["GlintMac"])
    ],
    dependencies: [
        .package(path: "../GlintCore"),
        .package(path: "../GlintRimeRelayCore"),
    ],
    targets: [
        .target(
            name: "GlintMac",
            dependencies: [
                .product(name: "GlintCore", package: "GlintCore"),
                .product(
                    name: "GlintRimeRelayCore",
                    package: "GlintRimeRelayCore"
                ),
            ],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("ApplicationServices"),
                .linkedFramework("Carbon"),
                .linkedFramework("Translation"),
            ]
        ),
        .testTarget(
            name: "GlintMacTests",
            dependencies: [
                "GlintMac",
                .product(
                    name: "GlintRimeRelayCore",
                    package: "GlintRimeRelayCore"
                ),
            ]
        ),
    ],
    swiftLanguageModes: [.v6]
)
