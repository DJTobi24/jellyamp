// swift-tools-version:5.9
import PackageDescription

// NOTE: auth via the official jellyfin-sdk-swift (QuickConnect helper) is
// added in Phase 1 once we can verify it builds for our targets; Phase 0
// keeps this package dependency-free apart from JellyampCore so it stays
// Linux-testable. The REST surface we need for music is small and stable.
let package = Package(
    name: "JellyfinBackend",
    platforms: [.iOS(.v16), .macOS(.v13)],
    products: [
        .library(name: "JellyfinBackend", targets: ["JellyfinBackend"])
    ],
    dependencies: [
        .package(path: "../JellyampCore")
    ],
    targets: [
        .target(name: "JellyfinBackend", dependencies: ["JellyampCore"]),
        .testTarget(
            name: "JellyfinBackendTests",
            dependencies: ["JellyfinBackend"],
            resources: [.copy("Fixtures")]
        ),
        // Runs against a real Jellyfin server (scripts/dev-jellyfin/up.sh);
        // every test skips itself unless JELLYFIN_TEST_URL/_USER/_PASSWORD are set.
        .testTarget(name: "JellyfinLiveTests", dependencies: ["JellyfinBackend"]),
    ]
)
