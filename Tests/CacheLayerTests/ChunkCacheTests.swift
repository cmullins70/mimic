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

@Test func chunkFilesAndRootAreOwnerOnly() async throws {
    let dir = try tempDir()
    let cache = try ChunkCache(directory: dir, byteLimit: 1_000_000)
    let key = ChunkKey(connectionID: "c", path: "/f", contentStamp: "s")
    await cache.store(Data("secret".utf8), for: key, index: 0)
    let fm = FileManager.default
    let rootPerms = try fm.attributesOfItem(atPath: dir.path)[.posixPermissions] as? NSNumber
    #expect(rootPerms?.intValue == 0o700)
    let sub = try #require(fm.contentsOfDirectory(atPath: dir.path).first)
    let filePath = dir.appendingPathComponent(sub).appendingPathComponent("0").path
    let filePerms = try fm.attributesOfItem(atPath: filePath)[.posixPermissions] as? NSNumber
    #expect(filePerms?.intValue == 0o600)
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
