// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "RimeCandidateLab",
    platforms: [.macOS("26.0")],
    products: [
        .executable(
            name: "RimeCandidateBridge",
            targets: ["RimeCandidateBridge"]
        )
    ],
    dependencies: [
        .package(path: "../../Packages/GlintCore"),
        .package(path: "../../Packages/GlintMac"),
    ],
    targets: [
        .executableTarget(
            name: "RimeCandidateBridge",
            dependencies: [
                .product(name: "GlintCore", package: "GlintCore"),
                .product(name: "GlintMac", package: "GlintMac"),
            ]
        )
    ],
    swiftLanguageModes: [.v6]
)
