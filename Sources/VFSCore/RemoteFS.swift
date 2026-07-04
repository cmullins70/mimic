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
