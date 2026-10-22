// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "HUDMaterialLab",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "HUDMaterialLab"
        )
    ],
    swiftLanguageModes: [.v6]
)
