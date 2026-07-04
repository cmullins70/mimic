import Testing
import Foundation
import VFSCore
@testable import CacheLayer

private final class Clock: @unchecked Sendable {
    var now: Date
    init(_ now: Date) { self.now = now }
}

@Test func servesWithinTTLAndExpiresAfter() throws {
    let clock = Clock(Date(timeIntervalSince1970: 1000))
    let cache = MetadataCache(ttl: 5, now: { clock.now })
    let p = try RemotePath("/f")
    let attrs = FileAttributes(type: .file, size: 1, modified: .now, permissions: 0o644)

    cache.setAttributes(attrs, for: p)
    #expect(cache.attributes(for: p) == attrs)

    clock.now = clock.now.addingTimeInterval(6)
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
