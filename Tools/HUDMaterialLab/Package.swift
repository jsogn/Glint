// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "HUDMaterialLab",
    platforms: [.macOS("26.0")],
    targets: [
        .executableTarget(
            name: "HUDMaterialLab"
        )
    ],
    swiftLanguageModes: [.v6]
)
