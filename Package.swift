// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MimicCore",
    platforms: [.macOS("15.0")],
    products: [
        .library(name: "VFSCore", targets: ["VFSCore"]),
        .library(name: "CacheLayer", targets: ["CacheLayer"]),
        .library(name: "ConnectionStore", targets: ["ConnectionStore"]),
        .library(name: "SFTPBackend", targets: ["SFTPBackend"]),
        .executable(name: "mimic-cli", targets: ["mimic-cli"]),
    ],
    dependencies: [
        // Pinned exact: 0.12.1 silently swapped its swift-nio-ssh dependency to an
        // unvetted personal fork (Wellz26/swift-nio-ssh) via an unreviewed PR.
        // 0.12.0 is the last release pulling from the Citadel maintainer's own fork.
        // Do not bump without reviewing Citadel's dependency URLs. See task #15 /
        // spec §7 risk 5 before changing.
        .package(url: "https://github.com/orlandos-nl/Citadel.git", exact: "0.12.0"),
    ],
    targets: [
        .target(name: "VFSCore"),
        .target(name: "CacheLayer", dependencies: ["VFSCore"]),
        .target(name: "ConnectionStore"),
        .target(name: "SFTPBackend", dependencies: ["VFSCore", "ConnectionStore", "Citadel"]),
        .executableTarget(
            name: "mimic-cli",
            dependencies: ["VFSCore", "CacheLayer", "ConnectionStore", "SFTPBackend"]),
        .testTarget(name: "VFSCoreTests", dependencies: ["VFSCore"]),
        .testTarget(name: "CacheLayerTests", dependencies: ["CacheLayer", "VFSCore"]),
        .testTarget(name: "ConnectionStoreTests", dependencies: ["ConnectionStore"]),
        .testTarget(name: "SFTPBackendTests", dependencies: ["SFTPBackend", "VFSCore"]),
    ]
)
