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
        // Apple's swift-nio (already resolved transitively via Citadel). Direct dep
        // so SFTPBackend can name ByteBuffer/NIOCore. This is upstream swift-nio,
        // NOT the swift-nio-ssh fork the Citadel note warns about.
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.101.0"),
        // The swift-nio-ssh fork Citadel already pulls (see Citadel note in this
        // file). Direct dep — SAME url + Citadel's identical version range, so
        // resolution is unchanged (still 0.3.5) — needed to name NIOSSHPublicKey /
        // the host-key validator delegate for TOFU verification. Dependabot-ignored
        // like Citadel; any bump needs the same manual supply-chain review.
        .package(url: "https://github.com/Joannis/swift-nio-ssh.git", "0.3.4" ..< "0.4.0"),
        // Apple's swift-crypto (already transitive) for SHA256 host-key fingerprints.
        .package(url: "https://github.com/apple/swift-crypto.git", from: "3.0.0"),
    ],
    targets: [
        .target(name: "VFSCore"),
        .target(name: "CacheLayer", dependencies: ["VFSCore"]),
        .target(name: "ConnectionStore"),
        .target(name: "SFTPBackend", dependencies: [
            "VFSCore", "ConnectionStore", "Citadel",
            .product(name: "NIOCore", package: "swift-nio"),
            .product(name: "NIOSSH", package: "swift-nio-ssh"),
            .product(name: "Crypto", package: "swift-crypto"),
        ]),
        .executableTarget(
            name: "mimic-cli",
            dependencies: ["VFSCore", "CacheLayer", "ConnectionStore", "SFTPBackend"]),
        .testTarget(name: "VFSCoreTests", dependencies: ["VFSCore"]),
        .testTarget(name: "CacheLayerTests", dependencies: ["CacheLayer", "VFSCore"]),
        .testTarget(name: "ConnectionStoreTests", dependencies: ["ConnectionStore"]),
        .testTarget(name: "SFTPBackendTests", dependencies: ["SFTPBackend", "VFSCore"]),
    ]
)
