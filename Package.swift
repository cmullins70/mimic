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
        .package(url: "https://github.com/orlandos-nl/Citadel.git", from: "0.7.0"),
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
