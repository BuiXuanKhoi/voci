// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "VolarCore",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .library(
            name: "VolarCore",
            targets: ["VolarCore"]
        )
    ],
    targets: [
        .target(
            name: "VolarCore",
            dependencies: []
        ),
        .testTarget(
            name: "VolarCoreTests",
            dependencies: ["VolarCore"]
        )
    ]
)
