// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "SonicClient",
    platforms: [.iOS(.v16), .macOS(.v13)],
    products: [
        .library(name: "SonicClient", targets: ["SonicClient"])
    ],
    dependencies: [
        .package(path: "../JellyampCore")
    ],
    targets: [
        .target(name: "SonicClient", dependencies: ["JellyampCore"]),
        .testTarget(
            name: "SonicClientTests",
            dependencies: ["SonicClient"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
