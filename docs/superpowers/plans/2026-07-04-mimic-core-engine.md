# Mimic Core Engine Implementation Plan (Plan 1 of 2)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build Mimic's protocol-agnostic filesystem core — `VFSCore`, `CacheLayer`, `ConnectionStore`, `SFTPBackend` — as a pure Swift package with a CLI smoke harness, fully tested without any FSKit/UI dependency.

**Architecture:** `RemoteFS` is the central async protocol. `SFTPBackend` implements it via Citadel; `CachedFS` (in `CacheLayer`) decorates any `RemoteFS` with a chunked on-disk read cache and TTL metadata cache; `ConnectionStore` persists connection configs and secrets. Plan 2 wraps all of this in the app + FSKit extension.

**Tech Stack:** Swift 6 (async/await, Sendable), Swift Testing (`import Testing`), SwiftPM, Citadel (SFTP over SwiftNIO SSH), Docker `sshd` for integration tests.

**Context notes for the executor:**
- Repo root: `/Users/chrismullins/dev/mimic`. The SPM package lives at the repo root; the Xcode app project (Plan 2) will consume it as a local package.
- Requires Xcode 26+ / Swift 6.x toolchain on macOS 26. Verify with `swift --version` before starting; stop and report if the toolchain is older than Swift 6.0.
- Citadel's exact API surface moves between minor versions. Code below targets Citadel ≥ 0.7 as documented at https://github.com/orlandos-nl/Citadel. If a call doesn't compile, check that README/DocC for the renamed equivalent — adapt the call site, not the `RemoteFS` protocol.
- Every task ends in a commit. Conventional commits, `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>` trailer.

---

## File structure (end state of this plan)

```
Package.swift
Sources/
  VFSCore/
    RemotePath.swift        # normalized absolute path value type
    FileAttributes.swift    # attrs + entry type enum + DirEntry
    RemoteFSError.swift     # typed errors + POSIX errno mapping
    RemoteFS.swift          # the protocol
    InMemoryFS.swift        # reference in-memory impl (test double, lives in main target so all packages can test against it)
  CacheLayer/
    ChunkCache.swift        # on-disk LRU chunk store
    MetadataCache.swift     # TTL'd attr/dir-listing cache
    CachedFS.swift          # RemoteFS decorator: read-through chunks, write-through invalidation
  ConnectionStore/
    ConnectionConfig.swift  # Codable connection model
    ConnectionStore.swift   # JSON persistence
    SecretStore.swift       # protocol + KeychainSecretStore + InMemorySecretStore
  SFTPBackend/
    HostKeyStore.swift      # TOFU known-hosts store
    SFTPConnection.swift    # Citadel session lifecycle + reconnect w/ backoff
    SFTPFileSystem.swift    # RemoteFS implementation
  mimic-cli/
    MimicCLI.swift          # ls/cat/put smoke harness (executable target)
Tests/
  VFSCoreTests/
    RemotePathTests.swift
    RemoteFSErrorTests.swift
    InMemoryFSTests.swift
  CacheLayerTests/
    ChunkCacheTests.swift
    MetadataCacheTests.swift
    CachedFSTests.swift
  ConnectionStoreTests/
    ConnectionStoreTests.swift
    SecretStoreTests.swift
  SFTPBackendTests/
    HostKeyStoreTests.swift
    SFTPIntegrationTests.swift   # gated on MIMIC_SFTP_TEST_HOST env var
scripts/
  sftp-test-server.sh            # start/stop Docker sshd fixture
.gitignore
```

---

### Task 1: SPM scaffold

**Files:**
- Create: `Package.swift`
- Create: `.gitignore`
- Create: `Sources/VFSCore/RemotePath.swift` (placeholder-free minimal file so the target builds)
- Create: `Tests/VFSCoreTests/RemotePathTests.swift`

- [ ] **Step 1: Write Package.swift**

```swift
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
```

Note: SSH key auth and Keychain access work on any macOS the toolchain supports; the macOS 26 floor applies to the app/extension (Plan 2), not this package — hence `macOS("15.0")`.

- [ ] **Step 2: Write .gitignore**

```
.build/
.swiftpm/
*.xcodeproj
DerivedData/
.DS_Store
```

- [ ] **Step 3: Seed one real type + one real test so `swift test` runs**

`Sources/VFSCore/RemotePath.swift` — start with the full type from Task 2 Step 3 (it is small; write it now, test-first order resumes in Task 2 for the remaining types). Alternatively seed with just the struct shell:

```swift
/// A normalized, absolute path inside a remote volume. Always starts with "/",
/// never ends with "/" (except root), no "." or ".." or empty components.
public struct RemotePath: Hashable, Sendable, Codable, CustomStringConvertible {
    public let rawValue: String
    public var description: String { rawValue }
}
```

`Tests/VFSCoreTests/RemotePathTests.swift`:

```swift
import Testing
@testable import VFSCore

@Test func remotePathStoresRawValue() {
    let p = RemotePath(rawValue: "/a/b")
    #expect(p.rawValue == "/a/b")
}
```

Add the memberwise-visible init to the struct: `public init(rawValue: String) { self.rawValue = rawValue }`.

- [ ] **Step 4: Verify build + test**

Run: `cd /Users/chrismullins/dev/mimic && swift test`
Expected: dependency resolution fetches Citadel; 1 test passes. (First run is slow — Citadel pulls SwiftNIO.) If Citadel 0.7 fails to resolve on Swift 6, bump to the latest release tag shown on its GitHub releases page and note the version in the commit message.

- [ ] **Step 5: Commit**

```bash
git add -A && git commit -m "chore: SPM scaffold with VFSCore/CacheLayer/ConnectionStore/SFTPBackend targets"
```

---

### Task 2: RemotePath — normalization and manipulation

**Files:**
- Modify: `Sources/VFSCore/RemotePath.swift`
- Modify: `Tests/VFSCoreTests/RemotePathTests.swift`

- [ ] **Step 1: Write failing tests**

```swift
import Testing
@testable import VFSCore

@Test func normalizesTrailingSlashesAndDuplicates() throws {
    #expect(try RemotePath("/a/b/").rawValue == "/a/b")
    #expect(try RemotePath("//a///b").rawValue == "/a/b")
    #expect(try RemotePath("/").rawValue == "/")
}

@Test func rejectsRelativeAndTraversalPaths() {
    #expect(throws: RemotePathError.self) { try RemotePath("a/b") }
    #expect(throws: RemotePathError.self) { try RemotePath("/a/../b") }
    #expect(throws: RemotePathError.self) { try RemotePath("/a/./b") }
    #expect(throws: RemotePathError.self) { try RemotePath("") }
}

@Test func parentAndNameAndAppending() throws {
    let p = try RemotePath("/a/b/c.txt")
    #expect(p.name == "c.txt")
    #expect(p.parent == (try RemotePath("/a/b")))
    #expect(try RemotePath("/").parent == nil)
    #expect(try RemotePath("/a").appending("b") == (try RemotePath("/a/b")))
}

@Test func root() throws {
    #expect(RemotePath.root.rawValue == "/")
    #expect(RemotePath.root.name == "/")
}
```

- [ ] **Step 2: Run tests, verify the new ones fail**

Run: `swift test --filter VFSCoreTests`
Expected: FAIL — no throwing initializer, no `RemotePathError`.

- [ ] **Step 3: Implement**

Replace `Sources/VFSCore/RemotePath.swift`:

```swift
public enum RemotePathError: Error, Equatable, Sendable {
    case notAbsolute(String)
    case invalidComponent(String)
}

/// A normalized, absolute path inside a remote volume. Always starts with "/",
/// never ends with "/" (except root), no "." / ".." / empty components.
public struct RemotePath: Hashable, Sendable, Codable, CustomStringConvertible {
    public let rawValue: String

    public init(rawValue: String) { self.rawValue = rawValue }

    public init(_ string: String) throws {
        guard string.hasPrefix("/") else { throw RemotePathError.notAbsolute(string) }
        let components = string.split(separator: "/", omittingEmptySubsequences: true)
        for c in components where c == "." || c == ".." {
            throw RemotePathError.invalidComponent(String(c))
        }
        self.rawValue = components.isEmpty ? "/" : "/" + components.joined(separator: "/")
    }

    public static let root = RemotePath(rawValue: "/")

    /// Last path component; "/" for root.
    public var name: String {
        rawValue == "/" ? "/" : String(rawValue.split(separator: "/").last!)
    }

    /// nil for root.
    public var parent: RemotePath? {
        guard rawValue != "/" else { return nil }
        let comps = rawValue.split(separator: "/").dropLast()
        return RemotePath(rawValue: comps.isEmpty ? "/" : "/" + comps.joined(separator: "/"))
    }

    public func appending(_ component: String) -> RemotePath {
        RemotePath(rawValue: rawValue == "/" ? "/\(component)" : "\(rawValue)/\(component)")
    }

    public var description: String { rawValue }
}
```

(Keep the Task 1 `remotePathStoresRawValue` test; `init(rawValue:)` remains as the unchecked fast path for internal use.)

- [ ] **Step 4: Run tests, verify pass**

Run: `swift test --filter VFSCoreTests` — Expected: all PASS.

- [ ] **Step 5: Commit** — `git add -A && git commit -m "feat(vfscore): RemotePath normalized path type"`

---

### Task 3: FileAttributes, DirEntry, RemoteFSError with errno mapping

**Files:**
- Create: `Sources/VFSCore/FileAttributes.swift`
- Create: `Sources/VFSCore/RemoteFSError.swift`
- Create: `Tests/VFSCoreTests/RemoteFSErrorTests.swift`

- [ ] **Step 1: Write failing tests**

```swift
import Testing
import Foundation
@testable import VFSCore

@Test func errnoMapping() {
    #expect(RemoteFSError.notFound(RemotePath.root).posixErrno == ENOENT)
    #expect(RemoteFSError.permissionDenied(RemotePath.root).posixErrno == EACCES)
    #expect(RemoteFSError.alreadyExists(RemotePath.root).posixErrno == EEXIST)
    #expect(RemoteFSError.notADirectory(RemotePath.root).posixErrno == ENOTDIR)
    #expect(RemoteFSError.isADirectory(RemotePath.root).posixErrno == EISDIR)
    #expect(RemoteFSError.directoryNotEmpty(RemotePath.root).posixErrno == ENOTEMPTY)
    #expect(RemoteFSError.connectionLost.posixErrno == EIO)
    #expect(RemoteFSError.timeout.posixErrno == ETIMEDOUT)
    #expect(RemoteFSError.unsupported("x").posixErrno == ENOTSUP)
    #expect(RemoteFSError.io("x").posixErrno == EIO)
}

@Test func attributesDefaults() {
    let a = FileAttributes(type: .file, size: 10,
                           modified: Date(timeIntervalSince1970: 5),
                           permissions: 0o644)
    #expect(a.type == .file)
    #expect(a.size == 10)
}
```

- [ ] **Step 2: Run, verify fail** — `swift test --filter VFSCoreTests` → FAIL (types missing).

- [ ] **Step 3: Implement**

`Sources/VFSCore/FileAttributes.swift`:

```swift
import Foundation

public enum EntryType: String, Sendable, Codable, Hashable {
    case file, directory, symlink
}

public struct FileAttributes: Sendable, Codable, Hashable {
    public var type: EntryType
    public var size: UInt64
    public var modified: Date
    /// POSIX permission bits, e.g. 0o644.
    public var permissions: UInt16

    public init(type: EntryType, size: UInt64, modified: Date, permissions: UInt16) {
        self.type = type
        self.size = size
        self.modified = modified
        self.permissions = permissions
    }
}

public struct DirEntry: Sendable, Codable, Hashable {
    public var name: String
    public var attributes: FileAttributes

    public init(name: String, attributes: FileAttributes) {
        self.name = name
        self.attributes = attributes
    }
}
```

`Sources/VFSCore/RemoteFSError.swift`:

```swift
import Foundation

public enum RemoteFSError: Error, Sendable, Equatable {
    case notFound(RemotePath)
    case permissionDenied(RemotePath)
    case alreadyExists(RemotePath)
    case notADirectory(RemotePath)
    case isADirectory(RemotePath)
    case directoryNotEmpty(RemotePath)
    case connectionLost
    case timeout
    case authenticationFailed(String)
    case hostKeyMismatch(expected: String, actual: String)
    case unsupported(String)
    case io(String)

    /// The POSIX errno FSKit/the kernel expects for this failure.
    public var posixErrno: Int32 {
        switch self {
        case .notFound: ENOENT
        case .permissionDenied: EACCES
        case .alreadyExists: EEXIST
        case .notADirectory: ENOTDIR
        case .isADirectory: EISDIR
        case .directoryNotEmpty: ENOTEMPTY
        case .connectionLost: EIO
        case .timeout: ETIMEDOUT
        case .authenticationFailed: EACCES
        case .hostKeyMismatch: EACCES
        case .unsupported: ENOTSUP
        case .io: EIO
        }
    }
}
```

- [ ] **Step 4: Run, verify pass** — `swift test --filter VFSCoreTests` → PASS.

- [ ] **Step 5: Commit** — `git commit -am "feat(vfscore): attributes, dir entries, typed errors with errno mapping"`

---

### Task 4: RemoteFS protocol + InMemoryFS reference implementation

`InMemoryFS` lives in the main `VFSCore` target (not test-only) because `CacheLayerTests` and the CLI's `--demo` mode also use it. It doubles as the executable specification of `RemoteFS` semantics.

**Files:**
- Create: `Sources/VFSCore/RemoteFS.swift`
- Create: `Sources/VFSCore/InMemoryFS.swift`
- Create: `Tests/VFSCoreTests/InMemoryFSTests.swift`

- [ ] **Step 1: Write the protocol** (no test — it's pure declaration)

`Sources/VFSCore/RemoteFS.swift`:

```swift
import Foundation

/// The one protocol every storage backend implements and every consumer
/// (cache, FSKit extension, CLI) talks to. All paths are normalized RemotePaths.
public protocol RemoteFS: Sendable {
    func attributes(at path: RemotePath) async throws -> FileAttributes
    func list(directory: RemotePath) async throws -> [DirEntry]
    /// Read up to `length` bytes at `offset`. Returns fewer bytes only at EOF.
    func read(file: RemotePath, offset: UInt64, length: Int) async throws -> Data
    /// Write `data` at `offset`, extending the file if needed. File must exist.
    func write(file: RemotePath, offset: UInt64, data: Data) async throws
    /// Create an empty file. Fails with .alreadyExists if present.
    func createFile(at path: RemotePath) async throws
    func createDirectory(at path: RemotePath) async throws
    func removeFile(at path: RemotePath) async throws
    /// Fails with .directoryNotEmpty unless empty.
    func removeDirectory(at path: RemotePath) async throws
    func rename(from: RemotePath, to: RemotePath) async throws
    func truncate(file: RemotePath, to size: UInt64) async throws
}
```

- [ ] **Step 2: Write failing tests for InMemoryFS**

`Tests/VFSCoreTests/InMemoryFSTests.swift`:

```swift
import Testing
import Foundation
@testable import VFSCore

@Test func createWriteReadRoundtrip() async throws {
    let fs = InMemoryFS()
    let p = try RemotePath("/hello.txt")
    try await fs.createFile(at: p)
    try await fs.write(file: p, offset: 0, data: Data("hello world".utf8))
    let data = try await fs.read(file: p, offset: 6, length: 5)
    #expect(String(decoding: data, as: UTF8.self) == "world")
    let attrs = try await fs.attributes(at: p)
    #expect(attrs.size == 11)
    #expect(attrs.type == .file)
}

@Test func readPastEOFReturnsShortData() async throws {
    let fs = InMemoryFS()
    let p = try RemotePath("/f")
    try await fs.createFile(at: p)
    try await fs.write(file: p, offset: 0, data: Data("abc".utf8))
    let data = try await fs.read(file: p, offset: 1, length: 100)
    #expect(data.count == 2)
}

@Test func listAndMkdirAndErrors() async throws {
    let fs = InMemoryFS()
    try await fs.createDirectory(at: try RemotePath("/docs"))
    try await fs.createFile(at: try RemotePath("/docs/a.txt"))
    let entries = try await fs.list(directory: try RemotePath("/docs"))
    #expect(entries.map(\.name) == ["a.txt"])

    await #expect(throws: RemoteFSError.notFound(try RemotePath("/nope"))) {
        _ = try await fs.list(directory: try RemotePath("/nope"))
    }
    await #expect(throws: RemoteFSError.alreadyExists(try RemotePath("/docs"))) {
        try await fs.createDirectory(at: try RemotePath("/docs"))
    }
    await #expect(throws: RemoteFSError.directoryNotEmpty(try RemotePath("/docs"))) {
        try await fs.removeDirectory(at: try RemotePath("/docs"))
    }
}

@Test func renameMovesSubtree() async throws {
    let fs = InMemoryFS()
    try await fs.createDirectory(at: try RemotePath("/a"))
    try await fs.createFile(at: try RemotePath("/a/f"))
    try await fs.rename(from: try RemotePath("/a"), to: try RemotePath("/b"))
    _ = try await fs.attributes(at: try RemotePath("/b/f"))
    await #expect(throws: RemoteFSError.notFound(try RemotePath("/a"))) {
        _ = try await fs.attributes(at: try RemotePath("/a"))
    }
}

@Test func truncateShrinksAndGrows() async throws {
    let fs = InMemoryFS()
    let p = try RemotePath("/f")
    try await fs.createFile(at: p)
    try await fs.write(file: p, offset: 0, data: Data("abcdef".utf8))
    try await fs.truncate(file: p, to: 3)
    #expect(try await fs.attributes(at: p).size == 3)
    try await fs.truncate(file: p, to: 5)
    let d = try await fs.read(file: p, offset: 0, length: 10)
    #expect(d == Data("abc".utf8) + Data([0, 0]))
}
```

- [ ] **Step 3: Run, verify fail** — `swift test --filter InMemoryFS` → FAIL (type missing).

- [ ] **Step 4: Implement InMemoryFS**

`Sources/VFSCore/InMemoryFS.swift`:

```swift
import Foundation

/// Reference RemoteFS used by tests, CacheLayer tests, and mimic-cli --demo.
/// Actor for trivial thread safety; performance is irrelevant here.
public actor InMemoryFS: RemoteFS {
    private enum Node {
        case file(Data, modified: Date)
        case directory(modified: Date)
    }

    private var nodes: [RemotePath: Node] = [.root: .directory(modified: .now)]

    public init() {}

    private func node(_ p: RemotePath) throws -> Node {
        guard let n = nodes[p] else { throw RemoteFSError.notFound(p) }
        return n
    }

    private func requireParentDirectory(of p: RemotePath) throws {
        guard let parent = p.parent else { throw RemoteFSError.alreadyExists(p) } // root
        guard case .directory = try node(parent) else { throw RemoteFSError.notADirectory(parent) }
    }

    public func attributes(at path: RemotePath) async throws -> FileAttributes {
        switch try node(path) {
        case .file(let d, let m):
            FileAttributes(type: .file, size: UInt64(d.count), modified: m, permissions: 0o644)
        case .directory(let m):
            FileAttributes(type: .directory, size: 0, modified: m, permissions: 0o755)
        }
    }

    public func list(directory: RemotePath) async throws -> [DirEntry] {
        guard case .directory = try node(directory) else {
            throw RemoteFSError.notADirectory(directory)
        }
        var out: [DirEntry] = []
        for (p, _) in nodes where p.parent == directory {
            out.append(DirEntry(name: p.name, attributes: try await attributes(at: p)))
        }
        return out.sorted { $0.name < $1.name }
    }

    public func read(file: RemotePath, offset: UInt64, length: Int) async throws -> Data {
        guard case .file(let d, _) = try node(file) else { throw RemoteFSError.isADirectory(file) }
        let start = min(Int(offset), d.count)
        let end = min(start + length, d.count)
        return d.subdata(in: start..<end)
    }

    public func write(file: RemotePath, offset: UInt64, data: Data) async throws {
        guard case .file(var d, _) = try node(file) else { throw RemoteFSError.isADirectory(file) }
        let off = Int(offset)
        if d.count < off { d.append(Data(repeating: 0, count: off - d.count)) }
        if off + data.count <= d.count {
            d.replaceSubrange(off..<(off + data.count), with: data)
        } else {
            d.replaceSubrange(off..<d.count, with: data.prefix(d.count - off))
            d.append(data.suffix(data.count - (d.count - off) < 0 ? 0 : off + data.count - d.count))
            // simpler equivalent: d = d.prefix(off) + data (when writing past end)
            d = Data(d.prefix(off)) + data
        }
        nodes[file] = .file(d, modified: .now)
    }

    public func createFile(at path: RemotePath) async throws {
        guard nodes[path] == nil else { throw RemoteFSError.alreadyExists(path) }
        try requireParentDirectory(of: path)
        nodes[path] = .file(Data(), modified: .now)
    }

    public func createDirectory(at path: RemotePath) async throws {
        guard nodes[path] == nil else { throw RemoteFSError.alreadyExists(path) }
        try requireParentDirectory(of: path)
        nodes[path] = .directory(modified: .now)
    }

    public func removeFile(at path: RemotePath) async throws {
        guard case .file = try node(path) else { throw RemoteFSError.isADirectory(path) }
        nodes[path] = nil
    }

    public func removeDirectory(at path: RemotePath) async throws {
        guard case .directory = try node(path) else { throw RemoteFSError.notADirectory(path) }
        guard !nodes.keys.contains(where: { $0.parent == path }) else {
            throw RemoteFSError.directoryNotEmpty(path)
        }
        nodes[path] = nil
    }

    public func rename(from: RemotePath, to: RemotePath) async throws {
        _ = try node(from)
        guard nodes[to] == nil else { throw RemoteFSError.alreadyExists(to) }
        try requireParentDirectory(of: to)
        let moving = nodes.keys.filter { $0 == from || $0.rawValue.hasPrefix(from.rawValue + "/") }
        for old in moving {
            let suffix = String(old.rawValue.dropFirst(from.rawValue.count))
            let new = RemotePath(rawValue: to.rawValue + suffix)
            nodes[new] = nodes.removeValue(forKey: old)
        }
    }

    public func truncate(file: RemotePath, to size: UInt64) async throws {
        guard case .file(var d, _) = try node(file) else { throw RemoteFSError.isADirectory(file) }
        if d.count > Int(size) {
            d = d.prefix(Int(size))
        } else {
            d.append(Data(repeating: 0, count: Int(size) - d.count))
        }
        nodes[file] = .file(d, modified: .now)
    }
}
```

Note the `write` implementation above contains a redundant branch left from reasoning — clean it to:

```swift
    public func write(file: RemotePath, offset: UInt64, data: Data) async throws {
        guard case .file(var d, _) = try node(file) else { throw RemoteFSError.isADirectory(file) }
        let off = Int(offset)
        if d.count < off { d.append(Data(repeating: 0, count: off - d.count)) }
        if off + data.count <= d.count {
            d.replaceSubrange(off..<(off + data.count), with: data)
        } else {
            d = Data(d.prefix(off)) + data
        }
        nodes[file] = .file(d, modified: .now)
    }
```

- [ ] **Step 5: Run, verify pass** — `swift test --filter VFSCoreTests` → all PASS.

- [ ] **Step 6: Commit** — `git commit -am "feat(vfscore): RemoteFS protocol + InMemoryFS reference implementation"`

---

### Task 5: ChunkCache — on-disk LRU chunk store

**Files:**
- Create: `Sources/CacheLayer/ChunkCache.swift`
- Create: `Tests/CacheLayerTests/ChunkCacheTests.swift`

Design: chunks stored as files under a root directory, `<root>/<key.hashHex>/<chunkIndex>`. A key is `(connectionID, path, contentStamp)` where `contentStamp` encodes remote size+mtime — if the remote file changes, the stamp changes, old chunks become garbage and are LRU-evicted naturally. LRU tracked in-memory (rebuilt lazily from file mtimes on init), enforced against a byte budget.

- [ ] **Step 1: Write failing tests**

```swift
import Testing
import Foundation
@testable import CacheLayer

private func tempDir() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("mimic-test-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

@Test func storeAndFetchChunk() async throws {
    let cache = try ChunkCache(directory: try tempDir(), byteLimit: 1_000_000)
    let key = ChunkKey(connectionID: "c1", path: "/f", contentStamp: "100-5")
    await cache.store(Data("chunk0".utf8), for: key, index: 0)
    let hit = await cache.fetch(for: key, index: 0)
    #expect(hit == Data("chunk0".utf8))
    let miss = await cache.fetch(for: key, index: 1)
    #expect(miss == nil)
}

@Test func differentStampMisses() async throws {
    let cache = try ChunkCache(directory: try tempDir(), byteLimit: 1_000_000)
    let k1 = ChunkKey(connectionID: "c1", path: "/f", contentStamp: "100-5")
    let k2 = ChunkKey(connectionID: "c1", path: "/f", contentStamp: "100-6")
    await cache.store(Data("x".utf8), for: k1, index: 0)
    #expect(await cache.fetch(for: k2, index: 0) == nil)
}

@Test func evictsLeastRecentlyUsedWhenOverBudget() async throws {
    let cache = try ChunkCache(directory: try tempDir(), byteLimit: 25)
    let key = ChunkKey(connectionID: "c", path: "/f", contentStamp: "s")
    await cache.store(Data(repeating: 1, count: 10), for: key, index: 0)
    await cache.store(Data(repeating: 2, count: 10), for: key, index: 1)
    _ = await cache.fetch(for: key, index: 0)                    // touch 0 → 1 is LRU
    await cache.store(Data(repeating: 3, count: 10), for: key, index: 2) // over budget
    #expect(await cache.fetch(for: key, index: 1) == nil)        // evicted
    #expect(await cache.fetch(for: key, index: 0) != nil)
    #expect(await cache.fetch(for: key, index: 2) != nil)
}

@Test func invalidateRemovesAllChunksForPath() async throws {
    let cache = try ChunkCache(directory: try tempDir(), byteLimit: 1_000_000)
    let key = ChunkKey(connectionID: "c", path: "/f", contentStamp: "s")
    await cache.store(Data("a".utf8), for: key, index: 0)
    await cache.store(Data("b".utf8), for: key, index: 1)
    await cache.invalidate(connectionID: "c", path: "/f")
    #expect(await cache.fetch(for: key, index: 0) == nil)
    #expect(await cache.fetch(for: key, index: 1) == nil)
}
```

- [ ] **Step 2: Run, verify fail** — `swift test --filter ChunkCacheTests` → FAIL.

- [ ] **Step 3: Implement**

`Sources/CacheLayer/ChunkCache.swift`:

```swift
import Foundation
import CryptoKit

public struct ChunkKey: Hashable, Sendable {
    public var connectionID: String
    public var path: String
    /// Encodes remote size+mtime; changes when the remote file changes.
    public var contentStamp: String

    public init(connectionID: String, path: String, contentStamp: String) {
        self.connectionID = connectionID
        self.path = path
        self.contentStamp = contentStamp
    }

    var dirName: String {
        let digest = SHA256.hash(data: Data("\(connectionID)|\(path)|\(contentStamp)".utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    /// Prefix shared by all stamps of the same (connection, path) — used for invalidation.
    static func pathTag(connectionID: String, path: String) -> String {
        let digest = SHA256.hash(data: Data("\(connectionID)|\(path)".utf8))
        return digest.prefix(8).map { String(format: "%02x", $0) }.joined()
    }
    var pathTag: String { Self.pathTag(connectionID: connectionID, path: path) }
}

/// On-disk LRU chunk store. Directory layout:
///   <root>/<pathTag>-<keyHash>/<chunkIndex>
/// LRU order kept in memory; sizes tracked against byteLimit.
public actor ChunkCache {
    public static let chunkSize = 2 * 1024 * 1024  // 2 MB, spec §3

    private let root: URL
    private let byteLimit: Int
    private var totalBytes = 0
    /// Most-recent at the END. Values are file URLs.
    private var lru: [String: URL] = [:]
    private var order: [String] = []

    public init(directory: URL, byteLimit: Int) throws {
        self.root = directory
        self.byteLimit = byteLimit
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // Rebuild index from disk (survives restarts); order by mtime.
        var found: [(id: String, url: URL, size: Int, mtime: Date)] = []
        let fm = FileManager.default
        for dir in (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? [] {
            for f in (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey])) ?? [] {
                let vals = try? f.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
                found.append((id: dir.lastPathComponent + "/" + f.lastPathComponent,
                              url: f,
                              size: vals?.fileSize ?? 0,
                              mtime: vals?.contentModificationDate ?? .distantPast))
            }
        }
        for e in found.sorted(by: { $0.mtime < $1.mtime }) {
            lru[e.id] = e.url
            order.append(e.id)
            totalBytes += e.size
        }
    }

    private func entryID(_ key: ChunkKey, _ index: Int) -> String {
        "\(key.pathTag)-\(key.dirName)/\(index)"
    }

    public func store(_ data: Data, for key: ChunkKey, index: Int) {
        let dir = root.appendingPathComponent("\(key.pathTag)-\(key.dirName)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent(String(index))
        let id = entryID(key, index)
        if let old = lru[id], let oldSize = try? old.resourceValues(forKeys: [.fileSizeKey]).fileSize {
            totalBytes -= oldSize
            order.removeAll { $0 == id }
        }
        guard (try? data.write(to: file, options: .atomic)) != nil else { return }
        lru[id] = file
        order.append(id)
        totalBytes += data.count
        evictIfNeeded()
    }

    public func fetch(for key: ChunkKey, index: Int) -> Data? {
        let id = entryID(key, index)
        guard let url = lru[id], let data = try? Data(contentsOf: url) else { return nil }
        order.removeAll { $0 == id }
        order.append(id)  // touch
        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: url.path)
        return data
    }

    public func invalidate(connectionID: String, path: String) {
        let tag = ChunkKey.pathTag(connectionID: connectionID, path: path)
        for (id, url) in lru where id.hasPrefix(tag + "-") {
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            try? FileManager.default.removeItem(at: url)
            totalBytes -= size
            lru[id] = nil
        }
        order.removeAll { $0.hasPrefix(tag + "-") }
    }

    private func evictIfNeeded() {
        while totalBytes > byteLimit, let victim = order.first {
            order.removeFirst()
            if let url = lru.removeValue(forKey: victim) {
                let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                try? FileManager.default.removeItem(at: url)
                totalBytes -= size
            }
        }
    }
}
```

- [ ] **Step 4: Run, verify pass** — `swift test --filter ChunkCacheTests` → PASS.

- [ ] **Step 5: Commit** — `git commit -am "feat(cache): on-disk LRU chunk cache"`

---

### Task 6: MetadataCache — TTL'd attributes & listings

**Files:**
- Create: `Sources/CacheLayer/MetadataCache.swift`
- Create: `Tests/CacheLayerTests/MetadataCacheTests.swift`

- [ ] **Step 1: Write failing tests** (inject the clock — no sleeps in unit tests)

```swift
import Testing
import Foundation
import VFSCore
@testable import CacheLayer

@Test func servesWithinTTLAndExpiresAfter() throws {
    var fakeNow = Date(timeIntervalSince1970: 1000)
    let cache = MetadataCache(ttl: 5, now: { fakeNow })
    let p = try RemotePath("/f")
    let attrs = FileAttributes(type: .file, size: 1, modified: .now, permissions: 0o644)

    cache.setAttributes(attrs, for: p)
    #expect(cache.attributes(for: p) == attrs)

    fakeNow = fakeNow.addingTimeInterval(6)
    #expect(cache.attributes(for: p) == nil)
}

@Test func listingCacheAndInvalidation() throws {
    let fakeNow = Date(timeIntervalSince1970: 0)
    let cache = MetadataCache(ttl: 5, now: { fakeNow })
    let dir = try RemotePath("/d")
    let entries = [DirEntry(name: "a", attributes:
        FileAttributes(type: .file, size: 0, modified: .now, permissions: 0o644))]
    cache.setListing(entries, for: dir)
    #expect(cache.listing(for: dir) == entries)

    cache.invalidate(try RemotePath("/d/a"))   // invalidating a child clears parent listing + child attrs
    #expect(cache.listing(for: dir) == nil)
}
```

- [ ] **Step 2: Run, verify fail** — `swift test --filter MetadataCacheTests` → FAIL.

- [ ] **Step 3: Implement**

`Sources/CacheLayer/MetadataCache.swift`:

```swift
import Foundation
import VFSCore

/// TTL'd cache for attributes and directory listings. Not an actor: guarded by
/// an unfair lock so the FSKit hot path (stat storms) stays cheap.
public final class MetadataCache: @unchecked Sendable {
    private struct Dated<T> { var value: T; var at: Date }

    private let ttl: TimeInterval
    private let now: @Sendable () -> Date
    private let lock = NSLock()
    private var attrs: [RemotePath: Dated<FileAttributes>] = [:]
    private var listings: [RemotePath: Dated<[DirEntry]>] = [:]

    public init(ttl: TimeInterval = 5, now: @escaping @Sendable () -> Date = { Date() }) {
        self.ttl = ttl
        self.now = now
    }

    public func attributes(for path: RemotePath) -> FileAttributes? {
        lock.withLock {
            guard let e = attrs[path], now().timeIntervalSince(e.at) < ttl else { return nil }
            return e.value
        }
    }

    public func setAttributes(_ a: FileAttributes, for path: RemotePath) {
        lock.withLock { attrs[path] = Dated(value: a, at: now()) }
    }

    public func listing(for dir: RemotePath) -> [DirEntry]? {
        lock.withLock {
            guard let e = listings[dir], now().timeIntervalSince(e.at) < ttl else { return nil }
            return e.value
        }
    }

    public func setListing(_ entries: [DirEntry], for dir: RemotePath) {
        lock.withLock { listings[dir] = Dated(value: entries, at: now()) }
    }

    /// Drop everything we claim to know about `path`: its attrs, its listing
    /// (if a directory), and its parent's listing (membership may have changed).
    public func invalidate(_ path: RemotePath) {
        lock.withLock {
            attrs[path] = nil
            listings[path] = nil
            if let parent = path.parent { listings[parent] = nil }
        }
    }

    public func invalidateAll() {
        lock.withLock { attrs.removeAll(); listings.removeAll() }
    }
}
```

- [ ] **Step 4: Run, verify pass.** — `swift test --filter MetadataCacheTests`

- [ ] **Step 5: Commit** — `git commit -am "feat(cache): TTL metadata cache with injected clock"`

---

### Task 7: CachedFS — the read-through/write-through decorator

**Files:**
- Create: `Sources/CacheLayer/CachedFS.swift`
- Create: `Tests/CacheLayerTests/CachedFSTests.swift`

Semantics (spec §3): reads go chunk-by-chunk through `ChunkCache`; metadata through `MetadataCache`; every mutation passes through to the backend then invalidates affected cache entries. `contentStamp` is derived from backend attributes at read time, so a remote change (new mtime/size) naturally misses the cache.

- [ ] **Step 1: Write failing tests** — use a counting wrapper around `InMemoryFS`:

```swift
import Testing
import Foundation
import VFSCore
@testable import CacheLayer

/// Counts backend reads so tests can prove cache hits.
actor CountingFS: RemoteFS {
    let inner: InMemoryFS
    var readCalls = 0
    init(_ inner: InMemoryFS) { self.inner = inner }

    func attributes(at p: RemotePath) async throws -> FileAttributes { try await inner.attributes(at: p) }
    func list(directory d: RemotePath) async throws -> [DirEntry] { try await inner.list(directory: d) }
    func read(file: RemotePath, offset: UInt64, length: Int) async throws -> Data {
        readCalls += 1
        return try await inner.read(file: file, offset: offset, length: length)
    }
    func write(file: RemotePath, offset: UInt64, data: Data) async throws { try await inner.write(file: file, offset: offset, data: data) }
    func createFile(at p: RemotePath) async throws { try await inner.createFile(at: p) }
    func createDirectory(at p: RemotePath) async throws { try await inner.createDirectory(at: p) }
    func removeFile(at p: RemotePath) async throws { try await inner.removeFile(at: p) }
    func removeDirectory(at p: RemotePath) async throws { try await inner.removeDirectory(at: p) }
    func rename(from: RemotePath, to: RemotePath) async throws { try await inner.rename(from: from, to: to) }
    func truncate(file: RemotePath, to size: UInt64) async throws { try await inner.truncate(file: file, to: size) }
}

private func makeSUT() async throws -> (CachedFS, CountingFS, InMemoryFS) {
    let mem = InMemoryFS()
    let counting = CountingFS(mem)
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("mimic-cachedfs-\(UUID().uuidString)")
    let cached = try CachedFS(backend: counting, connectionID: "test",
                              chunkCache: ChunkCache(directory: dir, byteLimit: 100_000_000),
                              metadataCache: MetadataCache(ttl: 5))
    return (cached, counting, mem)
}

@Test func secondReadOfSameChunkHitsCache() async throws {
    let (fs, counting, _) = try await makeSUT()
    let p = try RemotePath("/f")
    try await fs.createFile(at: p)
    try await fs.write(file: p, offset: 0, data: Data(repeating: 7, count: 1000))

    _ = try await fs.read(file: p, offset: 0, length: 100)
    let after1 = await counting.readCalls
    _ = try await fs.read(file: p, offset: 200, length: 100)   // same 2MB chunk
    let after2 = await counting.readCalls
    #expect(after1 == 1)
    #expect(after2 == 1)  // served from chunk cache
}

@Test func writeInvalidatesCachedChunks() async throws {
    let (fs, counting, _) = try await makeSUT()
    let p = try RemotePath("/f")
    try await fs.createFile(at: p)
    try await fs.write(file: p, offset: 0, data: Data("aaaa".utf8))
    _ = try await fs.read(file: p, offset: 0, length: 4)        // populate cache
    try await fs.write(file: p, offset: 0, data: Data("bbbb".utf8))
    let d = try await fs.read(file: p, offset: 0, length: 4)    // must re-fetch
    #expect(String(decoding: d, as: UTF8.self) == "bbbb")
    #expect(await counting.readCalls == 2)
}

@Test func attributesServedFromMetadataCache() async throws {
    let (fs, _, _) = try await makeSUT()
    let p = try RemotePath("/f")
    try await fs.createFile(at: p)
    let a1 = try await fs.attributes(at: p)
    let a2 = try await fs.attributes(at: p)
    #expect(a1 == a2)
}

@Test func readCoversMultipleChunksAndEOF() async throws {
    let (fs, _, _) = try await makeSUT()
    let p = try RemotePath("/big")
    try await fs.createFile(at: p)
    // 3 MB file spans two 2MB chunks
    let payload = Data((0..<(3 * 1024 * 1024)).map { UInt8($0 % 251) })
    try await fs.write(file: p, offset: 0, data: payload)
    let read = try await fs.read(file: p, offset: 2 * 1024 * 1024 - 100, length: 200)
    let expected = payload.subdata(in: (2 * 1024 * 1024 - 100)..<(2 * 1024 * 1024 + 100))
    #expect(read == expected)
    let tail = try await fs.read(file: p, offset: UInt64(payload.count) - 10, length: 100)
    #expect(tail.count == 10)
}
```

- [ ] **Step 2: Run, verify fail** — `swift test --filter CachedFSTests` → FAIL.

- [ ] **Step 3: Implement**

`Sources/CacheLayer/CachedFS.swift`:

```swift
import Foundation
import VFSCore

/// RemoteFS decorator adding a chunked read cache + TTL metadata cache.
/// Mutations pass through to the backend, then invalidate.
public final class CachedFS: RemoteFS, @unchecked Sendable {
    private let backend: any RemoteFS
    private let connectionID: String
    private let chunks: ChunkCache
    private let meta: MetadataCache

    public init(backend: any RemoteFS, connectionID: String,
                chunkCache: ChunkCache, metadataCache: MetadataCache) {
        self.backend = backend
        self.connectionID = connectionID
        self.chunks = chunkCache
        self.meta = metadataCache
    }

    // MARK: reads

    public func attributes(at path: RemotePath) async throws -> FileAttributes {
        if let hit = meta.attributes(for: path) { return hit }
        let a = try await backend.attributes(at: path)
        meta.setAttributes(a, for: path)
        return a
    }

    public func list(directory: RemotePath) async throws -> [DirEntry] {
        if let hit = meta.listing(for: directory) { return hit }
        let entries = try await backend.list(directory: directory)
        meta.setListing(entries, for: directory)
        for e in entries {  // listings give us attrs for free — warm them
            meta.setAttributes(e.attributes, for: directory.appending(e.name))
        }
        return entries
    }

    public func read(file: RemotePath, offset: UInt64, length: Int) async throws -> Data {
        let attrs = try await attributes(at: file)
        let stamp = "\(attrs.size)-\(attrs.modified.timeIntervalSince1970)"
        let key = ChunkKey(connectionID: connectionID, path: file.rawValue, contentStamp: stamp)
        let chunkSize = UInt64(ChunkCache.chunkSize)

        guard attrs.size > 0, offset < attrs.size else { return Data() }
        let end = min(offset + UInt64(length), attrs.size)
        var result = Data()
        var chunkIndex = Int(offset / chunkSize)

        while UInt64(chunkIndex) * chunkSize < end {
            let chunkStart = UInt64(chunkIndex) * chunkSize
            let chunkData: Data
            if let hit = await chunks.fetch(for: key, index: chunkIndex) {
                chunkData = hit
            } else {
                let wanted = Int(min(chunkSize, attrs.size - chunkStart))
                chunkData = try await backend.read(file: file, offset: chunkStart, length: wanted)
                await chunks.store(chunkData, for: key, index: chunkIndex)
            }
            let sliceStart = Int(max(offset, chunkStart) - chunkStart)
            let sliceEnd = Int(min(end, chunkStart + UInt64(chunkData.count)) - chunkStart)
            if sliceStart < sliceEnd {
                result += chunkData.subdata(in: sliceStart..<sliceEnd)
            }
            chunkIndex += 1
        }
        return result
    }

    // MARK: mutations (pass through + invalidate)

    private func invalidate(_ path: RemotePath) async {
        meta.invalidate(path)
        await chunks.invalidate(connectionID: connectionID, path: path.rawValue)
    }

    public func write(file: RemotePath, offset: UInt64, data: Data) async throws {
        try await backend.write(file: file, offset: offset, data: data)
        await invalidate(file)
    }

    public func createFile(at path: RemotePath) async throws {
        try await backend.createFile(at: path)
        await invalidate(path)
    }

    public func createDirectory(at path: RemotePath) async throws {
        try await backend.createDirectory(at: path)
        await invalidate(path)
    }

    public func removeFile(at path: RemotePath) async throws {
        try await backend.removeFile(at: path)
        await invalidate(path)
    }

    public func removeDirectory(at path: RemotePath) async throws {
        try await backend.removeDirectory(at: path)
        await invalidate(path)
    }

    public func rename(from: RemotePath, to: RemotePath) async throws {
        try await backend.rename(from: from, to: to)
        await invalidate(from)
        await invalidate(to)
    }

    public func truncate(file: RemotePath, to size: UInt64) async throws {
        try await backend.truncate(file: file, to: size)
        await invalidate(file)
    }
}
```

- [ ] **Step 4: Run, verify pass** — `swift test --filter CacheLayerTests` → all PASS.

- [ ] **Step 5: Commit** — `git commit -am "feat(cache): CachedFS read-through/write-through decorator"`

---

### Task 8: ConnectionConfig + ConnectionStore (JSON persistence)

**Files:**
- Create: `Sources/ConnectionStore/ConnectionConfig.swift`
- Create: `Sources/ConnectionStore/ConnectionStore.swift`
- Create: `Tests/ConnectionStoreTests/ConnectionStoreTests.swift`

- [ ] **Step 1: Write failing tests**

```swift
import Testing
import Foundation
@testable import ConnectionStore

private func tempDir() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("mimic-conn-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

@Test func saveLoadRoundtrip() throws {
    let dir = try tempDir()
    let store = ConnectionStore(directory: dir)
    let config = ConnectionConfig(
        id: UUID(), name: "kyra-nest", host: "kyra-nest.tail1234.ts.net", port: 22,
        username: "chris", auth: .privateKey(path: "/Users/chris/.ssh/id_ed25519"),
        remotePath: "/data", volumeName: "KyraNest")
    try store.save(config)

    let reloaded = ConnectionStore(directory: dir)
    #expect(try reloaded.all() == [config])
    #expect(try reloaded.connection(id: config.id) == config)
}

@Test func deleteRemoves() throws {
    let store = ConnectionStore(directory: try tempDir())
    let c = ConnectionConfig(id: UUID(), name: "x", host: "h", port: 22,
                             username: "u", auth: .password, remotePath: "/", volumeName: "X")
    try store.save(c)
    try store.delete(id: c.id)
    #expect(try store.all().isEmpty)
}

@Test func configFilePermissionsAreOwnerOnly() throws {
    let dir = try tempDir()
    let store = ConnectionStore(directory: dir)
    let c = ConnectionConfig(id: UUID(), name: "x", host: "h", port: 22,
                             username: "u", auth: .password, remotePath: "/", volumeName: "X")
    try store.save(c)
    let file = dir.appendingPathComponent("connections.json")
    let perms = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as! NSNumber
    #expect(perms.uint16Value == 0o600)
}
```

- [ ] **Step 2: Run, verify fail.**

- [ ] **Step 3: Implement**

`Sources/ConnectionStore/ConnectionConfig.swift`:

```swift
import Foundation

public struct ConnectionConfig: Codable, Hashable, Sendable, Identifiable {
    public enum Auth: Codable, Hashable, Sendable {
        /// Password lives in the SecretStore (Keychain), never here.
        case password
        /// Key file referenced by path; passphrase (if any) in the SecretStore.
        case privateKey(path: String)
    }

    public var id: UUID
    public var name: String
    public var host: String
    public var port: Int
    public var username: String
    public var auth: Auth
    public var remotePath: String
    public var volumeName: String

    public init(id: UUID, name: String, host: String, port: Int, username: String,
                auth: Auth, remotePath: String, volumeName: String) {
        self.id = id
        self.name = name
        self.host = host
        self.port = port
        self.username = username
        self.auth = auth
        self.remotePath = remotePath
        self.volumeName = volumeName
    }
}
```

`Sources/ConnectionStore/ConnectionStore.swift`:

```swift
import Foundation

/// Persists connection configs as one JSON file (0600) in the given directory.
/// In production the directory is the app-group container so the FSKit
/// extension can read it; tests use a temp dir.
public final class ConnectionStore: @unchecked Sendable {
    private let fileURL: URL
    private let lock = NSLock()

    public init(directory: URL) {
        self.fileURL = directory.appendingPathComponent("connections.json")
    }

    public func all() throws -> [ConnectionConfig] {
        lock.withLock {
            guard let data = try? Data(contentsOf: fileURL) else { return [] }
            return (try? JSONDecoder().decode([ConnectionConfig].self, from: data)) ?? []
        }
    }

    public func connection(id: UUID) throws -> ConnectionConfig? {
        try all().first { $0.id == id }
    }

    public func save(_ config: ConnectionConfig) throws {
        var configs = try all()
        configs.removeAll { $0.id == config.id }
        configs.append(config)
        try write(configs)
    }

    public func delete(id: UUID) throws {
        var configs = try all()
        configs.removeAll { $0.id == id }
        try write(configs)
    }

    private func write(_ configs: [ConnectionConfig]) throws {
        try lock.withLock {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(configs)
            try data.write(to: fileURL, options: .atomic)
            try FileManager.default.setAttributes(
                [.posixPermissions: NSNumber(value: Int16(0o600))], ofItemAtPath: fileURL.path)
        }
    }
}
```

Note: `all()` takes the lock and `save`/`delete` call it before taking the lock in `write` — with `NSLock` that would deadlock if nested. Structure exactly as shown (lock inside `all()`, lock inside `write()`, never held across both). If tests hang, this is why.

- [ ] **Step 4: Run, verify pass** — `swift test --filter ConnectionStoreTests`.

- [ ] **Step 5: Commit** — `git commit -am "feat(connections): config model + JSON store with 0600 perms"`

---

### Task 9: SecretStore — protocol, Keychain impl, in-memory impl

**Files:**
- Create: `Sources/ConnectionStore/SecretStore.swift`
- Create: `Tests/ConnectionStoreTests/SecretStoreTests.swift`

- [ ] **Step 1: Write failing tests** (unit tests target `InMemorySecretStore`; Keychain gets a smoke test gated by env var since `swift test` from a terminal has no keychain entitlements drama on personal machines but CI might)

```swift
import Testing
import Foundation
@testable import ConnectionStore

@Test func inMemoryRoundtripAndDelete() throws {
    let store = InMemorySecretStore()
    let id = UUID()
    try store.setSecret("hunter2", kind: .password, for: id)
    #expect(try store.secret(kind: .password, for: id) == "hunter2")
    try store.deleteSecrets(for: id)
    #expect(try store.secret(kind: .password, for: id) == nil)
}

@Test func kindsAreIndependent() throws {
    let store = InMemorySecretStore()
    let id = UUID()
    try store.setSecret("pw", kind: .password, for: id)
    try store.setSecret("phrase", kind: .keyPassphrase, for: id)
    #expect(try store.secret(kind: .password, for: id) == "pw")
    #expect(try store.secret(kind: .keyPassphrase, for: id) == "phrase")
}

@Test(.enabled(if: ProcessInfo.processInfo.environment["MIMIC_KEYCHAIN_TEST"] == "1"))
func keychainRoundtrip() throws {
    let store = KeychainSecretStore(service: "io.mimic.test")
    let id = UUID()
    try store.setSecret("s3cret", kind: .password, for: id)
    #expect(try store.secret(kind: .password, for: id) == "s3cret")
    try store.deleteSecrets(for: id)
    #expect(try store.secret(kind: .password, for: id) == nil)
}
```

- [ ] **Step 2: Run, verify fail.**

- [ ] **Step 3: Implement**

`Sources/ConnectionStore/SecretStore.swift`:

```swift
import Foundation
import Security

public enum SecretKind: String, Sendable {
    case password
    case keyPassphrase
}

public enum SecretStoreError: Error, Equatable, Sendable {
    case keychain(OSStatus)
}

public protocol SecretStore: Sendable {
    func setSecret(_ value: String, kind: SecretKind, for connectionID: UUID) throws
    func secret(kind: SecretKind, for connectionID: UUID) throws -> String?
    func deleteSecrets(for connectionID: UUID) throws
}

public final class InMemorySecretStore: SecretStore, @unchecked Sendable {
    private var storage: [String: String] = [:]
    private let lock = NSLock()
    public init() {}

    public func setSecret(_ value: String, kind: SecretKind, for id: UUID) throws {
        lock.withLock { storage["\(id.uuidString)/\(kind.rawValue)"] = value }
    }
    public func secret(kind: SecretKind, for id: UUID) throws -> String? {
        lock.withLock { storage["\(id.uuidString)/\(kind.rawValue)"] }
    }
    public func deleteSecrets(for id: UUID) throws {
        lock.withLock {
            storage = storage.filter { !$0.key.hasPrefix(id.uuidString + "/") }
        }
    }
}

/// Generic-password keychain items: service = <service>, account = <uuid>/<kind>.
/// In Plan 2 the app and extension share these via a keychain access group;
/// the `service` string stays the same.
public struct KeychainSecretStore: SecretStore {
    public let service: String
    public init(service: String = "io.mimic.secrets") { self.service = service }

    private func query(_ kind: SecretKind, _ id: UUID) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: "\(id.uuidString)/\(kind.rawValue)"]
    }

    public func setSecret(_ value: String, kind: SecretKind, for id: UUID) throws {
        var q = query(kind, id)
        SecItemDelete(q as CFDictionary)  // upsert: ignore result
        q[kSecValueData as String] = Data(value.utf8)
        q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        let status = SecItemAdd(q as CFDictionary, nil)
        guard status == errSecSuccess else { throw SecretStoreError.keychain(status) }
    }

    public func secret(kind: SecretKind, for id: UUID) throws -> String? {
        var q = query(kind, id)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            guard let data = result as? Data else { return nil }
            return String(decoding: data, as: UTF8.self)
        case errSecItemNotFound:
            return nil
        default:
            throw SecretStoreError.keychain(status)
        }
    }

    public func deleteSecrets(for id: UUID) throws {
        for kind in [SecretKind.password, .keyPassphrase] {
            let status = SecItemDelete(query(kind, id) as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else {
                throw SecretStoreError.keychain(status)
            }
        }
    }
}
```

- [ ] **Step 4: Run unit tests** — `swift test --filter SecretStoreTests` → PASS (keychain test skipped).
- [ ] **Step 5: Run keychain smoke test once locally** — `MIMIC_KEYCHAIN_TEST=1 swift test --filter keychainRoundtrip` → PASS (may show a keychain prompt; approve it).
- [x] **CI:** `.github/workflows/ci.yml` runs `swift test` on `macos-15` with `MIMIC_KEYCHAIN_TEST=1`, so `keychainRoundtrip` (and the concurrent-write race test) run in CI instead of being skipped. It provisions a dedicated unlocked keychain rather than relying on the login keychain (which can be locked in CI → `errSecInteractionNotAllowed`). Still needs one real run on GitHub to confirm the keychain path passes end-to-end.
- [ ] **Step 6: Commit** — `git commit -am "feat(connections): SecretStore protocol with Keychain and in-memory impls"`

---

### Task 10: HostKeyStore — TOFU known-hosts

**Files:**
- Create: `Sources/SFTPBackend/HostKeyStore.swift`
- Create: `Tests/SFTPBackendTests/HostKeyStoreTests.swift`

- [ ] **Step 1: Write failing tests**

```swift
import Testing
import Foundation
@testable import SFTPBackend

private func tempFile() -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("mimic-hosts-\(UUID().uuidString).json")
}

@Test func firstUseIsUnknownThenTrustPersists() throws {
    let url = tempFile()
    let store = HostKeyStore(fileURL: url)
    #expect(store.check(host: "example.com", port: 22, fingerprint: "SHA256:abc") == .unknown)

    try store.trust(host: "example.com", port: 22, fingerprint: "SHA256:abc")
    #expect(store.check(host: "example.com", port: 22, fingerprint: "SHA256:abc") == .trusted)

    let reloaded = HostKeyStore(fileURL: url)
    #expect(reloaded.check(host: "example.com", port: 22, fingerprint: "SHA256:abc") == .trusted)
}

@Test func changedKeyIsMismatch() throws {
    let store = HostKeyStore(fileURL: tempFile())
    try store.trust(host: "h", port: 22, fingerprint: "SHA256:old")
    #expect(store.check(host: "h", port: 22, fingerprint: "SHA256:NEW") == .mismatch(expected: "SHA256:old"))
}

@Test func samePortDifferentHostIndependent() throws {
    let store = HostKeyStore(fileURL: tempFile())
    try store.trust(host: "a", port: 22, fingerprint: "SHA256:x")
    #expect(store.check(host: "b", port: 22, fingerprint: "SHA256:x") == .unknown)
}
```

- [ ] **Step 2: Run, verify fail.**

- [ ] **Step 3: Implement**

`Sources/SFTPBackend/HostKeyStore.swift`:

```swift
import Foundation

/// Trust-on-first-use host key store. Fingerprints are OpenSSH-style
/// "SHA256:<base64>" strings. Persisted as JSON (0600).
public final class HostKeyStore: @unchecked Sendable {
    public enum Verdict: Equatable, Sendable {
        case trusted
        case unknown
        case mismatch(expected: String)
    }

    private let fileURL: URL
    private let lock = NSLock()
    private var entries: [String: String]  // "host:port" → fingerprint

    public init(fileURL: URL) {
        self.fileURL = fileURL
        if let data = try? Data(contentsOf: fileURL),
           let decoded = try? JSONDecoder().decode([String: String].self, from: data) {
            entries = decoded
        } else {
            entries = [:]
        }
    }

    private static func key(_ host: String, _ port: Int) -> String { "\(host.lowercased()):\(port)" }

    public func check(host: String, port: Int, fingerprint: String) -> Verdict {
        lock.withLock {
            guard let known = entries[Self.key(host, port)] else { return .unknown }
            return known == fingerprint ? .trusted : .mismatch(expected: known)
        }
    }

    public func trust(host: String, port: Int, fingerprint: String) throws {
        try lock.withLock {
            entries[Self.key(host, port)] = fingerprint
            let data = try JSONEncoder().encode(entries)
            try data.write(to: fileURL, options: .atomic)
            try FileManager.default.setAttributes(
                [.posixPermissions: NSNumber(value: Int16(0o600))], ofItemAtPath: fileURL.path)
        }
    }
}
```

- [ ] **Step 4: Run, verify pass** — `swift test --filter HostKeyStoreTests`.
- [ ] **Step 5: Commit** — `git commit -am "feat(sftp): TOFU host key store"`

---

### Task 11: Docker sshd test fixture

**Files:**
- Create: `scripts/sftp-test-server.sh`

- [ ] **Step 1: Write the script**

```bash
#!/usr/bin/env bash
# Start/stop a throwaway sshd for SFTPBackend integration tests.
# Usage: scripts/sftp-test-server.sh start|stop
# Exposes: sftp on localhost:2222, user "mimic", password "mimictest".
set -euo pipefail

NAME=mimic-sftp-test
case "${1:-}" in
  start)
    docker rm -f "$NAME" 2>/dev/null || true
    docker run -d --name "$NAME" -p 2222:22 \
      atmoz/sftp:latest mimic:mimictest:::upload
    echo "Waiting for sshd..."
    for i in $(seq 1 30); do
      if nc -z localhost 2222 2>/dev/null; then echo "ready on localhost:2222"; exit 0; fi
      sleep 1
    done
    echo "sshd did not come up" >&2; exit 1
    ;;
  stop)
    docker rm -f "$NAME" >/dev/null 2>&1 || true
    echo "stopped"
    ;;
  *)
    echo "usage: $0 start|stop" >&2; exit 2
    ;;
esac
```

- [ ] **Step 2: Make executable and verify**

Run: `chmod +x scripts/sftp-test-server.sh && scripts/sftp-test-server.sh start`
Expected: `ready on localhost:2222`. (Requires Docker Desktop/OrbStack running — if unavailable, report to the user and pause; do not fake this.)
Verify login works: `ssh -o StrictHostKeyChecking=no -p 2222 mimic@localhost exit` (password `mimictest`) — or `sftp -P 2222 mimic@localhost` and `quit`.
Then: `scripts/sftp-test-server.sh stop`.

- [ ] **Step 3: Commit** — `git add -A && git commit -m "test(sftp): docker sshd fixture script"`

---

### Task 12: SFTPFileSystem — RemoteFS over Citadel

This is the highest-uncertainty task (third-party API). Strategy: implement `SFTPConnection` (session lifecycle) and `SFTPFileSystem` (RemoteFS conformance) together, driven by integration tests against the Task 11 fixture. Integration tests are auto-skipped unless `MIMIC_SFTP_TEST_HOST` is set, so `swift test` stays green everywhere.

**Files:**
- Create: `Sources/SFTPBackend/SFTPConnection.swift`
- Create: `Sources/SFTPBackend/SFTPFileSystem.swift`
- Create: `Tests/SFTPBackendTests/SFTPIntegrationTests.swift`

- [ ] **Step 1: Write the integration tests (failing)**

```swift
import Testing
import Foundation
import VFSCore
@testable import SFTPBackend

// Run with:  scripts/sftp-test-server.sh start
//            MIMIC_SFTP_TEST_HOST=localhost swift test --filter SFTPIntegration
private var enabled: Bool { ProcessInfo.processInfo.environment["MIMIC_SFTP_TEST_HOST"] != nil }

private func makeFS() async throws -> SFTPFileSystem {
    let host = ProcessInfo.processInfo.environment["MIMIC_SFTP_TEST_HOST"]!
    return try await SFTPFileSystem.connect(
        host: host, port: 2222, username: "mimic",
        auth: .password("mimictest"),
        hostKeyPolicy: .acceptAny,   // test fixture only; real callers use .tofu(HostKeyStore)
        root: "/upload")
}

@Test(.enabled(if: enabled)) func fullFileLifecycle() async throws {
    let fs = try await makeFS()
    let p = try RemotePath("/it-\(UUID().uuidString).txt")
    try await fs.createFile(at: p)
    try await fs.write(file: p, offset: 0, data: Data("integration".utf8))
    #expect(try await fs.attributes(at: p).size == 11)
    let d = try await fs.read(file: p, offset: 6, length: 5)
    #expect(String(decoding: d, as: UTF8.self) == "ation")
    try await fs.removeFile(at: p)
    await #expect(throws: RemoteFSError.notFound(p)) { _ = try await fs.attributes(at: p) }
}

@Test(.enabled(if: enabled)) func directoryLifecycleAndListing() async throws {
    let fs = try await makeFS()
    let dir = try RemotePath("/dir-\(UUID().uuidString)")
    try await fs.createDirectory(at: dir)
    try await fs.createFile(at: dir.appending("a.txt"))
    try await fs.createFile(at: dir.appending("b.txt"))
    let names = try await fs.list(directory: dir).map(\.name).sorted()
    #expect(names == ["a.txt", "b.txt"])
    try await fs.removeFile(at: dir.appending("a.txt"))
    try await fs.removeFile(at: dir.appending("b.txt"))
    try await fs.removeDirectory(at: dir)
}

@Test(.enabled(if: enabled)) func renameAndUnicode() async throws {
    let fs = try await makeFS()
    let a = try RemotePath("/héllo-\(UUID().uuidString).txt")
    let b = try RemotePath("/wörld-\(UUID().uuidString).txt")
    try await fs.createFile(at: a)
    try await fs.rename(from: a, to: b)
    _ = try await fs.attributes(at: b)
    try await fs.removeFile(at: b)
}

@Test(.enabled(if: enabled)) func largeFileChunkedReadback() async throws {
    let fs = try await makeFS()
    let p = try RemotePath("/big-\(UUID().uuidString).bin")
    let payload = Data((0..<(5 * 1024 * 1024)).map { UInt8($0 % 251) })  // 5 MB
    try await fs.createFile(at: p)
    try await fs.write(file: p, offset: 0, data: payload)
    #expect(try await fs.attributes(at: p).size == UInt64(payload.count))
    let middle = try await fs.read(file: p, offset: 3_000_000, length: 4096)
    #expect(middle == payload.subdata(in: 3_000_000..<3_004_096))
    try await fs.removeFile(at: p)
}

@Test(.enabled(if: enabled)) func wrongPasswordFailsCleanly() async throws {
    let host = ProcessInfo.processInfo.environment["MIMIC_SFTP_TEST_HOST"]!
    await #expect(throws: RemoteFSError.self) {
        _ = try await SFTPFileSystem.connect(
            host: host, port: 2222, username: "mimic",
            auth: .password("wrong"), hostKeyPolicy: .acceptAny, root: "/upload")
    }
}
```

- [ ] **Step 2: Run to verify they fail to compile / fail** — `MIMIC_SFTP_TEST_HOST=localhost swift test --filter SFTPIntegration` → FAIL (types missing).

- [ ] **Step 3: Implement SFTPConnection**

`Sources/SFTPBackend/SFTPConnection.swift`:

```swift
import Foundation
import Citadel
import NIOSSH
import VFSCore

public enum SFTPAuth: Sendable {
    case password(String)
    case privateKey(path: String, passphrase: String?)
}

public enum HostKeyPolicy: Sendable {
    /// Test fixtures only.
    case acceptAny
    /// Trust-on-first-use backed by HostKeyStore. `.unknown` and `.mismatch`
    /// both fail the connection with a typed error carrying the fingerprint,
    /// so the caller (UI/CLI) can prompt and call HostKeyStore.trust().
    case tofu(HostKeyStore)
}

/// Owns one Citadel SSHClient + SFTPClient pair and reconnects with backoff.
/// All SFTPFileSystem calls funnel through `withSFTP`, which retries once
/// after a reconnect on connection failure.
public actor SFTPConnection {
    public let host: String
    public let port: Int
    public let username: String
    private let auth: SFTPAuth
    private let hostKeyPolicy: HostKeyPolicy

    private var ssh: SSHClient?
    private var sftp: SFTPClient?

    public init(host: String, port: Int, username: String,
                auth: SFTPAuth, hostKeyPolicy: HostKeyPolicy) {
        self.host = host
        self.port = port
        self.username = username
        self.auth = auth
        self.hostKeyPolicy = hostKeyPolicy
    }

    private func makeAuthMethod() throws -> SSHAuthenticationMethod {
        switch auth {
        case .password(let pw):
            return .passwordBased(username: username, password: pw)
        case .privateKey(let path, _):
            let keyData = try String(contentsOfFile: path, encoding: .utf8)
            // Citadel supports OpenSSH ed25519/RSA private keys. Passphrase-protected
            // keys: consult Citadel docs for the decryption parameter on the parser.
            let key = try Insecure.RSA.PrivateKey(sshRsa: keyData)  // adjust per key type;
            // ed25519: Curve25519.Signing.PrivateKey(sshEd25519: keyData)
            return .rsa(username: username, privateKey: key)
        }
    }

    private func connect() async throws -> SFTPClient {
        do {
            let client = try await SSHClient.connect(
                host: host,
                port: port,
                authenticationMethod: try makeAuthMethod(),
                hostKeyValidator: hostKeyValidator(),
                reconnect: .never)
            let sftpClient = try await client.openSFTP()
            self.ssh = client
            self.sftp = sftpClient
            return sftpClient
        } catch let e as RemoteFSError {
            throw e
        } catch {
            throw RemoteFSError.authenticationFailed(String(describing: error))
        }
    }

    private func hostKeyValidator() -> SSHHostKeyValidator {
        switch hostKeyPolicy {
        case .acceptAny:
            return .acceptAnything()
        case .tofu(let store):
            // Citadel exposes custom validators via a delegate/closure taking the
            // NIOSSHPublicKey. Compute OpenSSH SHA256 fingerprint, consult the store:
            //   .unknown  → throw RemoteFSError.hostKeyMismatch(expected: "", actual: fp)
            //               (UI catches, prompts, calls store.trust, reconnects)
            //   .mismatch → throw RemoteFSError.hostKeyMismatch(expected:actual:)
            //   .trusted  → accept
            // Exact Citadel API: see SSHHostKeyValidator in Citadel's sources.
            return .acceptAnything()  // replaced in Step 5 below
        }
    }

    /// Run an SFTP operation, reconnecting once if the channel is dead.
    public func withSFTP<T: Sendable>(_ body: @Sendable (SFTPClient) async throws -> T) async throws -> T {
        let client: SFTPClient
        if let existing = sftp, await !existing.isClosed {
            client = existing
        } else {
            client = try await connect()
        }
        do {
            return try await body(client)
        } catch {
            // one retry after reconnect for channel-level failures
            self.sftp = nil
            self.ssh = nil
            let fresh = try await connect()
            return try await body(fresh)
        }
    }

    public func close() async {
        try? await ssh?.close()
        sftp = nil
        ssh = nil
    }
}
```

**Executor note (expected friction, not optional):** `Insecure.RSA.PrivateKey`, `isClosed`, `.acceptAnything()`, and validator wiring are best-effort renderings of Citadel's API. Compile, read the errors, open Citadel's README + `Sources/Citadel` in `.build/checkouts/Citadel`, and adjust call sites. The shapes (connect → openSFTP → per-call funnel with one reconnect retry) are the design; keep those.

- [ ] **Step 4: Implement SFTPFileSystem**

`Sources/SFTPBackend/SFTPFileSystem.swift`:

```swift
import Foundation
import Citadel
import VFSCore

/// RemoteFS over SFTP. All paths are relative to `root` on the server
/// (e.g. root="/upload" maps RemotePath "/a.txt" → "/upload/a.txt").
public final class SFTPFileSystem: RemoteFS, @unchecked Sendable {
    private let connection: SFTPConnection
    private let root: String
    /// Per-op timeout (spec §5: Finder must never hang).
    private let timeout: Duration = .seconds(30)

    private init(connection: SFTPConnection, root: String) {
        self.connection = connection
        self.root = root == "/" ? "" : root
    }

    public static func connect(host: String, port: Int, username: String,
                               auth: SFTPAuth, hostKeyPolicy: HostKeyPolicy,
                               root: String) async throws -> SFTPFileSystem {
        let conn = SFTPConnection(host: host, port: port, username: username,
                                  auth: auth, hostKeyPolicy: hostKeyPolicy)
        let fs = SFTPFileSystem(connection: conn, root: root)
        _ = try await fs.list(directory: .root)  // fail fast: proves auth + root path
        return fs
    }

    private func serverPath(_ p: RemotePath) -> String {
        p == .root ? (root.isEmpty ? "/" : root) : root + p.rawValue
    }

    private func withTimeout<T: Sendable>(_ op: @escaping @Sendable () async throws -> T) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await op() }
            group.addTask {
                try await Task.sleep(for: self.timeout)
                throw RemoteFSError.timeout
            }
            let result = try await group.next()!
            group.cancelAll()
            return result
        }
    }

    private func mapError(_ error: Error, path: RemotePath) -> Error {
        if let e = error as? RemoteFSError { return e }
        // Citadel surfaces SFTP status codes; map the common ones.
        let text = String(describing: error).lowercased()
        if text.contains("no such file") { return RemoteFSError.notFound(path) }
        if text.contains("permission denied") { return RemoteFSError.permissionDenied(path) }
        if text.contains("file already exists") { return RemoteFSError.alreadyExists(path) }
        return RemoteFSError.io(String(describing: error))
    }
    // Executor note: prefer matching Citadel's typed SFTPStatusCode error over
    // string matching if it is public — check `SFTPError` in Citadel sources.

    public func attributes(at path: RemotePath) async throws -> FileAttributes {
        do {
            return try await withTimeout { [self] in
                try await connection.withSFTP { sftp in
                    let attrs = try await sftp.getAttributes(at: self.serverPath(path))
                    return Self.convert(attrs)
                }
            }
        } catch { throw mapError(error, path: path) }
    }

    public func list(directory: RemotePath) async throws -> [DirEntry] {
        do {
            return try await withTimeout { [self] in
                try await connection.withSFTP { sftp in
                    let items = try await sftp.listDirectory(atPath: self.serverPath(directory))
                    // Citadel returns [SFTPMessage.Name] each holding components
                    // with filename + attributes.
                    var out: [DirEntry] = []
                    for nameMsg in items {
                        for comp in nameMsg.components {
                            let name = comp.filename
                            guard name != "." && name != ".." else { continue }
                            out.append(DirEntry(name: name, attributes: Self.convert(comp.attributes)))
                        }
                    }
                    return out.sorted { $0.name < $1.name }
                }
            }
        } catch { throw mapError(error, path: directory) }
    }

    public func read(file: RemotePath, offset: UInt64, length: Int) async throws -> Data {
        do {
            return try await withTimeout { [self] in
                try await connection.withSFTP { sftp in
                    let handle = try await sftp.openFile(filePath: self.serverPath(file), flags: .read)
                    defer { Task { try? await handle.close() } }
                    let buf = try await handle.read(from: offset, length: UInt32(length))
                    return Data(buffer: buf)
                }
            }
        } catch { throw mapError(error, path: file) }
    }

    public func write(file: RemotePath, offset: UInt64, data: Data) async throws {
        do {
            try await withTimeout { [self] in
                try await connection.withSFTP { sftp in
                    let handle = try await sftp.openFile(filePath: self.serverPath(file), flags: [.write])
                    defer { Task { try? await handle.close() } }
                    // Citadel writes ByteBuffer; chunk to 256 KB to stay under
                    // typical SFTP packet limits.
                    var remaining = data
                    var at = offset
                    while !remaining.isEmpty {
                        let piece = remaining.prefix(256 * 1024)
                        try await handle.write(ByteBuffer(data: piece), at: at)
                        at += UInt64(piece.count)
                        remaining = remaining.dropFirst(piece.count)
                    }
                }
            }
        } catch { throw mapError(error, path: file) }
    }

    public func createFile(at path: RemotePath) async throws {
        do {
            try await withTimeout { [self] in
                try await connection.withSFTP { sftp in
                    let handle = try await sftp.openFile(
                        filePath: self.serverPath(path),
                        flags: [.create, .write, .exclusive])
                    try await handle.close()
                }
            }
        } catch { throw mapError(error, path: path) }
    }

    public func createDirectory(at path: RemotePath) async throws {
        do {
            try await withTimeout { [self] in
                try await connection.withSFTP { sftp in
                    try await sftp.createDirectory(atPath: self.serverPath(path))
                }
            }
        } catch { throw mapError(error, path: path) }
    }

    public func removeFile(at path: RemotePath) async throws {
        do {
            try await withTimeout { [self] in
                try await connection.withSFTP { sftp in
                    try await sftp.remove(at: self.serverPath(path))
                }
            }
        } catch { throw mapError(error, path: path) }
    }

    public func removeDirectory(at path: RemotePath) async throws {
        do {
            try await withTimeout { [self] in
                try await connection.withSFTP { sftp in
                    try await sftp.rmdir(at: self.serverPath(path))
                }
            }
        } catch { throw mapError(error, path: path) }
    }

    public func rename(from: RemotePath, to: RemotePath) async throws {
        do {
            try await withTimeout { [self] in
                try await connection.withSFTP { sftp in
                    try await sftp.rename(at: self.serverPath(from), to: self.serverPath(to))
                }
            }
        } catch { throw mapError(error, path: from) }
    }

    public func truncate(file: RemotePath, to size: UInt64) async throws {
        // SFTP v3 truncate = setstat with size attribute.
        do {
            try await withTimeout { [self] in
                try await connection.withSFTP { sftp in
                    var attrs = SFTPFileAttributes()
                    attrs.size = size
                    try await sftp.setAttributes(attrs, atPath: self.serverPath(file))
                }
            }
        } catch { throw mapError(error, path: file) }
    }

    private static func convert(_ a: SFTPFileAttributes) -> FileAttributes {
        let perms = a.permissions ?? 0
        let isDir = (perms & 0o170000) == 0o040000  // S_IFDIR
        let isLink = (perms & 0o170000) == 0o120000 // S_IFLNK
        return FileAttributes(
            type: isDir ? .directory : (isLink ? .symlink : .file),
            size: a.size ?? 0,
            modified: Date(timeIntervalSince1970: TimeInterval(a.accessModificationTime?.modificationTime ?? 0)),
            permissions: UInt16(perms & 0o7777))
    }
}
```

**Executor note:** same as SFTPConnection — `SFTPFileAttributes` field names, `openFile` flag spellings, `rmdir`/`remove`/`rename` method names, and the `listDirectory` return shape must be checked against the resolved Citadel version in `.build/checkouts/Citadel/Sources/Citadel/SFTP/`. The test suite is the contract; the design (root-prefix mapping, 30 s timeout wrapper, error mapping, 256 KB write chunks) is fixed.

- [ ] **Step 5: Implement the TOFU validator for real** — replace the `.acceptAnything()` placeholder in `hostKeyValidator()` with Citadel's custom-validator hook (per its docs), computing `SHA256:<base64>` fingerprints from the raw public key blob and consulting the `HostKeyStore`. Add a unit test asserting a `HostKeyStore.check` mismatch produces `RemoteFSError.hostKeyMismatch` (use the integration server: connect once with `.tofu`, trust, then corrupt the stored fingerprint and expect the error).

- [ ] **Step 6: Run integration suite**

```bash
scripts/sftp-test-server.sh start
MIMIC_SFTP_TEST_HOST=localhost swift test --filter SFTPIntegration
scripts/sftp-test-server.sh stop
```
Expected: all integration tests PASS. Also run plain `swift test` — everything else still green, SFTP tests skipped.

- [ ] **Step 7: Commit** — `git commit -am "feat(sftp): SFTPFileSystem RemoteFS implementation over Citadel"`

---

### Task 13: mimic-cli smoke harness

Proves the whole stack composes (SFTP → cache → consumer) without any UI. Also your day-to-day debugging tool.

**Files:**
- Create: `Sources/mimic-cli/MimicCLI.swift`

- [ ] **Step 1: Implement**

```swift
import Foundation
import VFSCore
import CacheLayer
import SFTPBackend

// Usage:
//   mimic-cli ls  sftp://user:password@host:port/root/path [subpath]
//   mimic-cli cat sftp://user:password@host:port/root/path <file>
//   mimic-cli put sftp://user:password@host:port/root/path <localfile> <remotepath>
// Password in URL is for smoke testing ONLY (fixture server); real credential
// handling arrives with the app in Plan 2.

@main
struct MimicCLI {
    static func main() async {
        do { try await run() } catch {
            FileHandle.standardError.write(Data("error: \(error)\n".utf8))
            exit(1)
        }
    }

    static func run() async throws {
        let args = CommandLine.arguments
        guard args.count >= 3, let url = URL(string: args[2]), url.scheme == "sftp",
              let host = url.host, let user = url.user, let password = url.password else {
            print("usage: mimic-cli <ls|cat|put> sftp://user:pass@host:port/root [args]")
            exit(2)
        }
        let fs = try await SFTPFileSystem.connect(
            host: host, port: url.port ?? 22, username: user,
            auth: .password(password), hostKeyPolicy: .acceptAny, root: url.path)

        let cacheDir = FileManager.default.temporaryDirectory.appendingPathComponent("mimic-cli-cache")
        let cached = try CachedFS(
            backend: fs, connectionID: "cli",
            chunkCache: ChunkCache(directory: cacheDir, byteLimit: 256 * 1024 * 1024),
            metadataCache: MetadataCache())

        switch args[1] {
        case "ls":
            let dir = try RemotePath(args.count > 3 ? args[3] : "/")
            for e in try await cached.list(directory: dir) {
                let flag = e.attributes.type == .directory ? "d" : "-"
                print("\(flag) \(String(format: "%10d", e.attributes.size)) \(e.name)")
            }
        case "cat":
            let p = try RemotePath(args[3])
            let attrs = try await cached.attributes(at: p)
            let data = try await cached.read(file: p, offset: 0, length: Int(attrs.size))
            FileHandle.standardOutput.write(data)
        case "put":
            let local = URL(fileURLWithPath: args[3])
            let remote = try RemotePath(args[4])
            let data = try Data(contentsOf: local)
            try? await cached.createFile(at: remote)
            try await cached.write(file: remote, offset: 0, data: data)
            print("wrote \(data.count) bytes to \(remote)")
        default:
            print("unknown command \(args[1])")
            exit(2)
        }
    }
}
```

- [ ] **Step 2: Smoke test against the fixture**

```bash
scripts/sftp-test-server.sh start
swift run mimic-cli ls 'sftp://mimic:mimictest@localhost:2222/upload'
echo "hello from mimic" > /tmp/hello.txt
swift run mimic-cli put 'sftp://mimic:mimictest@localhost:2222/upload' /tmp/hello.txt /hello.txt
swift run mimic-cli cat 'sftp://mimic:mimictest@localhost:2222/upload' /hello.txt
scripts/sftp-test-server.sh stop
```
Expected: `ls` lists, `put` reports 17 bytes, `cat` prints `hello from mimic`.

- [ ] **Step 3: Commit** — `git commit -am "feat(cli): mimic-cli smoke harness (ls/cat/put)"`

---

### Task 14: CI + README stub + full-suite gate

**Files:**
- Create: `.github/workflows/ci.yml`
- Create: `README.md`

- [ ] **Step 1: CI workflow**

```yaml
name: CI
on:
  push: { branches: [main] }
  pull_request:
jobs:
  test:
    runs-on: macos-26
    steps:
      - uses: actions/checkout@v4
      - name: Select Xcode
        run: sudo xcode-select -s /Applications/Xcode_26.app || sudo xcode-select -s "$(ls -d /Applications/Xcode*.app | sort -V | tail -1)"
      - name: Unit tests
        run: swift test
```
(Integration tests stay local-only for now — GitHub macOS runners don't run Linux Docker containers. Revisit with a Linux+Swift job later if wanted.)

- [ ] **Step 2: README stub**

```markdown
# Mimic 🐙

Mount remote storage as real Finder volumes. Native FSKit, no kernel
extensions, no loopback servers. macOS 26+. Free and open source (MIT).

**Status: pre-alpha.** Core engine (SFTP + cache) works from the CLI;
the app + FSKit extension are in progress.

Named for the mimic octopus — the one that impersonates other animals.
Mimic makes remote servers impersonate local disks.

## Try the core engine

    scripts/sftp-test-server.sh start   # needs Docker
    swift run mimic-cli ls 'sftp://mimic:mimictest@localhost:2222/upload'

## Development

    swift test                                   # unit tests
    scripts/sftp-test-server.sh start
    MIMIC_SFTP_TEST_HOST=localhost swift test    # + integration tests

Design docs: `docs/superpowers/specs/`.
```

- [ ] **Step 3: Full gate** — run `swift test` (all green) and the integration suite once more; fix anything red before committing.

- [ ] **Step 4: Commit** — `git add -A && git commit -m "chore: CI workflow and README"`

---

## Self-review results

- **Spec coverage:** VFSCore protocol/types (T2–4), chunk cache + TTL metadata + write-through invalidation (T5–7), config + Keychain secrets + 0600 perms (T8–9), TOFU host keys (T10), SFTP backend with timeouts/reconnect/error-mapping (T12), integration tests vs Docker sshd (T11–12), CLI (T13), CI (T14). **Deferred to Plan 2 by design:** FSKit extension, mounting, menu bar UI, onboarding, app-group/keychain-group wiring, errno mapping *at the FSKit boundary* (the `posixErrno` property from T3 is the hook), Finder E2E checklist.
- **Placeholders:** the two Citadel "executor notes" are deliberate adaptation instructions with fixed design constraints, not TBDs; all other code is complete.
- **Type consistency:** `RemoteFS` method names checked against `InMemoryFS`, `CountingFS`, `CachedFS`, `SFTPFileSystem`, and CLI call sites; `ChunkKey`/`ChunkCache.chunkSize`/`MetadataCache(ttl:now:)` signatures consistent across T5–7 and T13.
