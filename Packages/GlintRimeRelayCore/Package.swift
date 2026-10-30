// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "GlintRimeRelayCore",
    platforms: [.macOS("15.0")],
    products: [
        .library(
            name: "GlintRimeRelayCore",
            targets: ["GlintRimeRelayCore"]
        )
    ],
    targets: [
        .target(name: "GlintRimeRelayCore"),
        .testTarget(
            name: "GlintRimeRelayCoreTests",
            dependencies: ["GlintRimeRelayCore"]
        ),
    ],
    swiftLanguageModes: [.v6]
)
