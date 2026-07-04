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
