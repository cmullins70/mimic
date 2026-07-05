import Foundation
import Citadel
import NIOCore
import VFSCore

/// `RemoteFS` over SFTP. All paths are relative to `root` on the server
/// (e.g. root="/upload" maps RemotePath "/a.txt" → "/upload/a.txt").
public final class SFTPFileSystem: RemoteFS, @unchecked Sendable {
    private let connection: SFTPConnection
    private let root: String
    /// Per-op timeout (spec §5: Finder must never hang).
    private let timeout: Duration = .seconds(30)
    /// SFTP packet payloads must stay well under the protocol max; 256 KB is a
    /// safe, widely-used chunk for both reads and writes.
    private static let chunkSize = 256 * 1024

    private init(connection: SFTPConnection, root: String) {
        self.connection = connection
        self.root = root == "/" ? "" : root
    }

    public static func connect(host: String, port: Int, username: String,
                               auth: SFTPAuth, hostKeyPolicy: HostKeyPolicy,
                               root: String) async throws -> SFTPFileSystem {
        let conn = SFTPConnection(host: host, port: port, username: username,
                                  auth: auth, hostKeyPolicy: hostKeyPolicy)
        let fs = SFTPFileSystem(connection: conn, root: root)
        _ = try await fs.list(directory: .root)  // fail fast: proves auth + root path
        return fs
    }

    public func close() async { await connection.close() }

    private func serverPath(_ p: RemotePath) -> String {
        p == .root ? (root.isEmpty ? "/" : root) : root + p.rawValue
    }

    private func withTimeout<T: Sendable>(_ op: @escaping @Sendable () async throws -> T) async throws -> T {
        do {
            return try await withThrowingTaskGroup(of: T.self) { group in
                group.addTask { try await op() }
                group.addTask {
                    try await Task.sleep(for: self.timeout)
                    throw RemoteFSError.timeout
                }
                let result = try await group.next()!
                group.cancelAll()
                return result
            }
        } catch let error as RemoteFSError where error == .timeout {
            // Citadel/NIOSSH calls may not observe Task cancellation, so the losing
            // op task above may still be blocked inside a wedged SFTP request. Tear
            // the connection down so a half-wedged SFTPClient is never silently
            // reused by the next liveSFTP(); the next op reconnects fresh.
            await connection.invalidate()
            throw error
        }
    }

    private func mapError(_ error: Error, path: RemotePath) -> Error {
        if let e = error as? RemoteFSError { return e }
        // Citadel surfaces a failed op either wrapped (SFTPError.errorStatus) or
        // as a bare SFTPMessage.Status (e.g. getAttributes) — handle both.
        if case let SFTPError.errorStatus(status) = error { return Self.mapStatus(status, path: path) }
        if let status = error as? SFTPMessage.Status { return Self.mapStatus(status, path: path) }
        // A dropped transport surfaces as SFTPError.connectionClosed (every
        // in-flight request promise is failed with it when the SFTP channel
        // closes) or a NIO ChannelError on a write to a dead channel.
        // Canonicalize both to .connectionLost so the FS layer has one error
        // vocabulary for a dead connection instead of leaking it as .io.
        if case SFTPError.connectionClosed = error { return RemoteFSError.connectionLost }
        if let ce = error as? ChannelError {
            switch ce {
            case .ioOnClosedChannel, .alreadyClosed, .eof: return RemoteFSError.connectionLost
            default: break
            }
        }
        return RemoteFSError.io(String(describing: error))
    }

    private static func mapStatus(_ status: SFTPMessage.Status, path: RemotePath) -> RemoteFSError {
        switch status.errorCode {
        case .noSuchFile: return .notFound(path)
        case .permissionDenied: return .permissionDenied(path)
        case .connectionLost, .noConnection: return .connectionLost
        default: return .io("SFTP status \(status.errorCode): \(status.message)")
        }
    }

    public func attributes(at path: RemotePath) async throws -> FileAttributes {
        let sp = serverPath(path)
        do {
            return try await withTimeout {
                // Pure read → idempotent, safe to retry once on a dropped transport.
                try await self.connection.withSFTP(retryOnDrop: true) { sftp in
                    Self.convert(try await sftp.getAttributes(at: sp))
                }
            }
        } catch { throw mapError(error, path: path) }
    }

    public func list(directory: RemotePath) async throws -> [DirEntry] {
        let sp = serverPath(directory)
        do {
            return try await withTimeout {
                // Directory listing is a pure read → idempotent, safe to retry.
                try await self.connection.withSFTP(retryOnDrop: true) { sftp in
                    let names = try await sftp.listDirectory(atPath: sp)
                    var out: [DirEntry] = []
                    for name in names {
                        for comp in name.components where comp.filename != "." && comp.filename != ".." {
                            out.append(DirEntry(name: comp.filename, attributes: Self.convert(comp.attributes)))
                        }
                    }
                    return out.sorted { $0.name < $1.name }
                }
            }
        } catch { throw mapError(error, path: directory) }
    }

    public func read(file: RemotePath, offset: UInt64, length: Int) async throws -> Data {
        let sp = serverPath(file)
        do {
            return try await withTimeout {
                // Offset-addressed read → idempotent; the whole open/read/close is
                // safe to re-run on a dropped transport.
                try await self.connection.withSFTP(retryOnDrop: true) { sftp in
                    let handle = try await sftp.openFile(filePath: sp, flags: .read)
                    do {
                        var out = Data()
                        var pos = offset
                        // Loop so the contract holds ("fewer bytes only at EOF")
                        // even if the server caps a single read below `length`.
                        while out.count < length {
                            let want = UInt32(min(length - out.count, Self.chunkSize))
                            let chunk = try await handle.read(from: pos, length: want)
                            if chunk.readableBytes == 0 { break }  // EOF
                            out.append(Data(chunk.readableBytesView))
                            pos += UInt64(chunk.readableBytes)
                        }
                        try await handle.close()
                        return out
                    } catch {
                        try? await handle.close()
                        throw error
                    }
                }
            }
        } catch { throw mapError(error, path: file) }
    }

    public func write(file: RemotePath, offset: UInt64, data: Data) async throws {
        let sp = serverPath(file)
        do {
            try await withTimeout {
                // Offset-addressed write of the same bytes → idempotent (no append,
                // no truncate): re-running writes identical data at identical
                // offsets, so retry-on-drop is safe.
                try await self.connection.withSFTP(retryOnDrop: true) { sftp in
                    let handle = try await sftp.openFile(filePath: sp, flags: [.write])
                    do {
                        var at = offset
                        var start = data.startIndex
                        while start < data.endIndex {
                            let end = data.index(start, offsetBy: Self.chunkSize, limitedBy: data.endIndex) ?? data.endIndex
                            let piece = data[start..<end]
                            var buf = ByteBufferAllocator().buffer(capacity: piece.count)
                            buf.writeBytes(piece)
                            try await handle.write(buf, at: at)
                            at += UInt64(piece.count)
                            start = end
                        }
                        try await handle.close()
                    } catch {
                        try? await handle.close()
                        throw error
                    }
                }
            }
        } catch { throw mapError(error, path: file) }
    }

    public func createFile(at path: RemotePath) async throws {
        let sp = serverPath(path)
        do {
            try await withTimeout {
                try await self.connection.withSFTP { sftp in
                    // .forceCreate is SSH_FXF_EXCL: fail if it already exists.
                    let handle = try await sftp.openFile(filePath: sp, flags: [.create, .write, .forceCreate])
                    try await handle.close()
                }
            }
        } catch { throw mapError(error, path: path) }
    }

    public func createDirectory(at path: RemotePath) async throws {
        let sp = serverPath(path)
        do {
            try await withTimeout {
                try await self.connection.withSFTP { sftp in
                    try await sftp.createDirectory(atPath: sp)
                }
            }
        } catch { throw mapError(error, path: path) }
    }

    public func removeFile(at path: RemotePath) async throws {
        let sp = serverPath(path)
        do {
            try await withTimeout {
                try await self.connection.withSFTP { sftp in
                    try await sftp.remove(at: sp)
                }
            }
        } catch { throw mapError(error, path: path) }
    }

    public func removeDirectory(at path: RemotePath) async throws {
        let sp = serverPath(path)
        do {
            try await withTimeout {
                try await self.connection.withSFTP { sftp in
                    try await sftp.rmdir(at: sp)
                }
            }
        } catch { throw mapError(error, path: path) }
    }

    public func rename(from: RemotePath, to: RemotePath) async throws {
        let spFrom = serverPath(from)
        let spTo = serverPath(to)
        do {
            try await withTimeout {
                try await self.connection.withSFTP { sftp in
                    try await sftp.rename(at: spFrom, to: spTo)
                }
            }
        } catch { throw mapError(error, path: from) }
    }

    public func truncate(file: RemotePath, to size: UInt64) async throws {
        let sp = serverPath(file)
        do {
            try await withTimeout {
                // set-size is idempotent (setting the same size twice is a no-op)
                // → safe to retry on a dropped transport.
                try await self.connection.withSFTP(retryOnDrop: true) { sftp in
                    // SFTP v3 truncate == setstat with just the size attribute.
                    try await sftp.setAttributes(at: sp, to: SFTPFileAttributes(size: size))
                }
            }
        } catch { throw mapError(error, path: file) }
    }

    private static func convert(_ a: SFTPFileAttributes) -> FileAttributes {
        let perms = a.permissions ?? 0
        let isDir = (perms & 0o170000) == 0o040000   // S_IFDIR
        let isLink = (perms & 0o170000) == 0o120000  // S_IFLNK
        return FileAttributes(
            type: isDir ? .directory : (isLink ? .symlink : .file),
            size: a.size ?? 0,
            modified: a.accessModificationTime?.modificationTime ?? Date(timeIntervalSince1970: 0),
            permissions: UInt16(perms & 0o7777))
    }
}
