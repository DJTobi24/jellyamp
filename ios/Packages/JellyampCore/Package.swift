// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "JellyampCore",
    platforms: [.iOS(.v16), .macOS(.v13)],
    products: [
        .library(name: "JellyampCore", targets: ["JellyampCore"])
    ],
    targets: [
        .target(name: "JellyampCore"),
        .testTarget(name: "JellyampCoreTests", dependencies: ["JellyampCore"]),
    ]
)
