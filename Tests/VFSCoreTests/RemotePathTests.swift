import Testing
@testable import VFSCore

@Test func remotePathStoresRawValue() {
    let p = RemotePath(rawValue: "/a/b")
    #expect(p.rawValue == "/a/b")
}
