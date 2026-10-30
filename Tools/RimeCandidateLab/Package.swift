// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "RimeCandidateLab",
    platforms: [.macOS("15.0")],
    products: [
        .executable(
            name: "RimeCandidateBridge",
            targets: ["RimeCandidateBridge"]
        )
    ],
    dependencies: [
        .package(path: "../../Packages/GlintRimeRelayCore")
    ],
    targets: [
        .executableTarget(
            name: "RimeCandidateBridge",
            dependencies: [
                .product(
                    name: "GlintRimeRelayCore",
                    package: "GlintRimeRelayCore"
                )
            ]
        )
    ],
    swiftLanguageModes: [.v6]
)
