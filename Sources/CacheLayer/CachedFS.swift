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
