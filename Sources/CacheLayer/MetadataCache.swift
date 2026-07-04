import Foundation
import VFSCore

/// TTL'd cache for attributes and directory listings. Not an actor: guarded by
/// a lock so the FSKit hot path (stat storms) stays cheap.
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
