// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "GlintMac",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "GlintMac", targets: ["GlintMac"]),
    ],
    dependencies: [
        .package(path: "../GlintCore"),
    ],
    targets: [
        .target(
            name: "GlintONNXRuntime",
            path: "Sources/GlintONNXRuntime",
            publicHeadersPath: "include",
            cSettings: [
                .headerSearchPath("vendorinclude"),
            ]
        ),
        .target(
            name: "GlintMac",
            dependencies: [
                .product(name: "GlintCore", package: "GlintCore"),
                "GlintONNXRuntime",
            ],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("ScreenCaptureKit"),
                .linkedFramework("Vision"),
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
