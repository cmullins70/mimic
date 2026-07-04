import Testing
import Foundation
import VFSCore
@testable import CacheLayer

/// Counts backend reads so tests can prove cache hits.
actor CountingFS: RemoteFS {
    let inner: InMemoryFS
    var readCalls = 0
    var attrCalls = 0
    init(_ inner: InMemoryFS) { self.inner = inner }

    func attributes(at p: RemotePath) async throws -> FileAttributes {
        attrCalls += 1
        return try await inner.attributes(at: p)
    }
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
    let (fs, counting, _) = try await makeSUT()
    let p = try RemotePath("/f")
    try await fs.createFile(at: p)
    let a1 = try await fs.attributes(at: p)
    let a2 = try await fs.attributes(at: p)
    #expect(a1 == a2)
    #expect(await counting.attrCalls == 1)  // second call served from metadata cache
}

/// Backend whose listing contains a server-controlled hostile entry name.
private struct HostileListingFS: RemoteFS {
    static let fileAttrs = FileAttributes(type: .file, size: 4, modified: Date(timeIntervalSince1970: 100), permissions: 0o644)

    func attributes(at path: RemotePath) async throws -> FileAttributes { Self.fileAttrs }
    func list(directory: RemotePath) async throws -> [DirEntry] {
        [DirEntry(name: "evil/sibling", attributes: Self.fileAttrs),
         DirEntry(name: "normal", attributes: Self.fileAttrs)]
    }
    func read(file: RemotePath, offset: UInt64, length: Int) async throws -> Data { Data() }
    func write(file: RemotePath, offset: UInt64, data: Data) async throws {}
    func createFile(at path: RemotePath) async throws {}
    func createDirectory(at path: RemotePath) async throws {}
    func removeFile(at path: RemotePath) async throws {}
    func removeDirectory(at path: RemotePath) async throws {}
    func rename(from: RemotePath, to: RemotePath) async throws {}
    func truncate(file: RemotePath, to size: UInt64) async throws {}
}

@Test func hostileListingNamesDoNotPoisonAttrsCache() async throws {
    let meta = MetadataCache(ttl: 60)
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("mimic-cachedfs-\(UUID().uuidString)")
    let fs = try CachedFS(backend: HostileListingFS(), connectionID: "test",
                          chunkCache: ChunkCache(directory: dir, byteLimit: 100_000_000),
                          metadataCache: meta)

    let entries = try await fs.list(directory: try RemotePath("/dir"))
    // The listing itself is passed through untouched — both entries are data.
    #expect(entries.map(\.name) == ["evil/sibling", "normal"])
    // But the hostile name must NOT have warmed an attrs entry outside /dir.
    #expect(meta.attributes(for: RemotePath(rawValue: "/dir/evil/sibling")) == nil)
    // The well-formed sibling was warmed normally.
    #expect(meta.attributes(for: try RemotePath("/dir/normal")) == HostileListingFS.fileAttrs)
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
