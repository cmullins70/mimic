import Foundation

public enum RemoteFSError: Error, Sendable, Equatable {
    case notFound(RemotePath)
    case permissionDenied(RemotePath)
    case alreadyExists(RemotePath)
    case notADirectory(RemotePath)
    case isADirectory(RemotePath)
    case directoryNotEmpty(RemotePath)
    case connectionLost
    case timeout
    case authenticationFailed(String)
    case hostKeyMismatch(expected: String, actual: String)
    case unsupported(String)
    case io(String)

    /// The POSIX errno FSKit/the kernel expects for this failure.
    public var posixErrno: Int32 {
        switch self {
        case .notFound: ENOENT
        case .permissionDenied: EACCES
        case .alreadyExists: EEXIST
        case .notADirectory: ENOTDIR
        case .isADirectory: EISDIR
        case .directoryNotEmpty: ENOTEMPTY
        case .connectionLost: EIO
        case .timeout: ETIMEDOUT
        case .authenticationFailed: EACCES
        case .hostKeyMismatch: EACCES
        case .unsupported: ENOTSUP
        case .io: EIO
        }
    }
}
