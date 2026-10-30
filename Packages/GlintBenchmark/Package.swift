// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "GlintBenchmark",
    platforms: [.macOS("15.0")],
    products: [
        .executable(name: "GlintBenchmark", targets: ["GlintBenchmark"])
    ],
    dependencies: [
        .package(path: "../GlintCore"),
        .package(path: "../GlintDictionary"),
    ],
    targets: [
        .executableTarget(
            name: "GlintBenchmark",
            dependencies: [
                .product(name: "GlintCore", package: "GlintCore"),
                .product(name: "GlintDictionary", package: "GlintDictionary"),
            ]
        )
    ],
    swiftLanguageModes: [.v6]
)
