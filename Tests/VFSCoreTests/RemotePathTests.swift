import Testing
@testable import VFSCore

@Test func remotePathStoresRawValue() {
    let p = RemotePath(rawValue: "/a/b")
    #expect(p.rawValue == "/a/b")
}

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
