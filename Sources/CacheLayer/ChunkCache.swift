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
        // Chunk files hold remote file content — owner-only access on the root.
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        // Rebuild index from disk (survives restarts); order by mtime.
        var found: [(id: String, url: URL, size: Int, mtime: Date)] = []
        let fm = FileManager.default
        for dir in (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? [] {
            for f in (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [] {
                let attrs = try? fm.attributesOfItem(atPath: f.path)
                let size = (attrs?[.size] as? Int) ?? 0
                let mtime = (attrs?[.modificationDate] as? Date) ?? .distantPast
                found.append((id: dir.lastPathComponent + "/" + f.lastPathComponent,
                              url: f,
                              size: size,
                              mtime: mtime))
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

    private func fileSize(at url: URL) -> Int {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int ?? 0
    }

    public func store(_ data: Data, for key: ChunkKey, index: Int) {
        let dir = root.appendingPathComponent("\(key.pathTag)-\(key.dirName)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent(String(index))
        let id = entryID(key, index)
        // Read the old size BEFORE the write, but only adjust accounting after the
        // write succeeds — a failed write leaves the old file (and its tracking) intact.
        let oldSize = lru[id] != nil ? fileSize(at: file) : nil
        guard (try? data.write(to: file, options: .atomic)) != nil else { return }
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        if let oldSize {
            totalBytes -= oldSize
            order.removeAll { $0 == id }
        }
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
            let size = fileSize(at: url)
            try? FileManager.default.removeItem(at: url)
            // Only drop tracking if the file is actually gone — a failed delete that
            // leaves the file behind must stay accounted, or its bytes leak untracked.
            guard !FileManager.default.fileExists(atPath: url.path) else { continue }
            totalBytes -= size
            lru[id] = nil
            order.removeAll { $0 == id }
        }
    }

    private func evictIfNeeded() {
        // stuckCount = consecutive victims whose deletes failed; once it reaches the
        // number of tracked entries every candidate is undeletable — stop, no progress.
        var stuckCount = 0
        while totalBytes > byteLimit, stuckCount < order.count, let victim = order.first {
            order.removeFirst()
            guard let url = lru[victim] else { continue }
            let size = fileSize(at: url)
            try? FileManager.default.removeItem(at: url)
            if FileManager.default.fileExists(atPath: url.path) {
                // Delete failed and the file remains: keep it tracked (bytes and all),
                // move to the most-recent end so the loop doesn't spin on it.
                order.append(victim)
                stuckCount += 1
            } else {
                lru[victim] = nil
                totalBytes -= size
                stuckCount = 0
            }
        }
    }
}
