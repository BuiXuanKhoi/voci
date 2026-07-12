// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "VociCore",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .library(
            name: "VociCore",
            targets: ["VociCore"]
        )
    ],
    targets: [
        .target(
            name: "VociCore",
            dependencies: []
        ),
        .testTarget(
            name: "VociCoreTests",
            dependencies: ["VociCore"]
        )
    ]
)
