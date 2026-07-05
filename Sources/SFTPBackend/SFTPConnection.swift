import Foundation
import Citadel
import NIOCore
import VFSCore

public enum SFTPAuth: Sendable {
    case password(String)
    case privateKey(path: String, passphrase: String?)
}

public enum HostKeyPolicy: Sendable {
    /// Accepts any host key. Test fixtures / throwaway localhost servers ONLY.
    case acceptAny
    /// Trust-on-first-use backed by `HostKeyStore` (see `TOFUHostKeyValidator`).
    /// Fails closed on an unknown or changed host key with
    /// `RemoteFSError.hostKeyMismatch`.
    case tofu(HostKeyStore)
}

/// Owns one Citadel `SSHClient` + `SFTPClient` for a single server.
///
/// Citadel's `SSHClient` and `SSHAuthenticationMethod` are non-Sendable, so this
/// wrapper is `@unchecked Sendable`: the mutable client refs are guarded by
/// `lock` (held only for synchronous get/set, never across `await`), and the
/// actual SFTP I/O runs on Citadel's own thread-safe, `Sendable` `SFTPClient`.
///
/// Resilience: `withSFTP` reconnects once and retries if an operation fails
/// because the transport died mid-flight; concurrent first-use is coalesced by a
/// single-flight connect `Task` so redundant SSH sessions are never opened.
public final class SFTPConnection: @unchecked Sendable {
    public let host: String
    public let port: Int
    public let username: String
    private let auth: SFTPAuth
    private let hostKeyPolicy: HostKeyPolicy

    private let lock = NSLock()
    private var ssh: SSHClient?
    private var sftp: SFTPClient?
    /// In-flight connect, guarded by `lock`. Concurrent callers await the same
    /// `Task` instead of each starting a redundant `SSHClient.connect`.
    private var connectingTask: Task<SFTPClient, Error>?

    public init(host: String, port: Int, username: String,
                auth: SFTPAuth, hostKeyPolicy: HostKeyPolicy) {
        self.host = host
        self.port = port
        self.username = username
        self.auth = auth
        self.hostKeyPolicy = hostKeyPolicy
    }

    private func makeAuthMethod() throws -> SSHAuthenticationMethod {
        switch auth {
        case .password(let pw):
            return .passwordBased(username: username, password: pw)
        case .privateKey:
            // Loading OpenSSH private keys (RSA/ed25519, optional passphrase) via
            // Citadel is not wired yet; fail closed rather than silently degrade.
            throw RemoteFSError.unsupported("SFTP private-key auth not implemented yet")
        }
    }

    private func makeHostKeyValidator() throws -> SSHHostKeyValidator {
        switch hostKeyPolicy {
        case .acceptAny:
            return .acceptAnything()
        case .tofu(let store):
            // Trust-on-first-use: compute the server's SHA256 fingerprint and
            // consult the store. Fails closed on unknown/mismatch (see
            // TOFUHostKeyValidator). The hostKeyMismatch error propagates unwrapped
            // through SSHClient.connect and is rethrown by connect()'s RemoteFSError
            // catch below.
            return .custom(TOFUHostKeyValidator(store: store, host: host, port: port))
        }
    }

    private func liveSFTP() -> SFTPClient? {
        lock.withLock {
            if let s = sftp, s.isActive { return s }
            return nil
        }
    }

    /// Clear the current client refs under the lock so the next call reconnects.
    /// Does NOT close the channel (the transport is presumed already dead); use
    /// `invalidate()` for a best-effort close of a possibly-wedged client.
    private func dropClient() {
        lock.withLock {
            ssh = nil
            sftp = nil
        }
    }

    /// Whether `error` indicates the transport died and a reconnect is warranted.
    ///
    /// Reconnect is gated on THIS classification (a dead transport) — never on a
    /// real/non-transient failure. We key off the error CASE, not `.posixErrno`:
    /// `.connectionLost` and `.io` both map to EIO, so errno cannot distinguish a
    /// dead socket (retry) from a genuine I/O error (don't). The body of a
    /// `withSFTP` op throws RAW Citadel/NIO errors (it hasn't been through
    /// `SFTPFileSystem.mapError` yet), so we must recognize those raw types here:
    ///   - `SFTPError.connectionClosed` — every in-flight request promise is
    ///     failed with this when the SFTP channel closes (`SFTPResponses.close`).
    ///     This is the actual error a mid-op drop surfaces.
    ///   - NIO `ChannelError.ioOnClosedChannel/.alreadyClosed/.eof` — a write to
    ///     an already-dead channel.
    ///   - `RemoteFSError.connectionLost` — in case a mapped error reaches here
    ///     (e.g. an SFTP status of connectionLost/noConnection).
    /// Everything else (auth, permission, notFound, unsupported, hostKeyMismatch,
    /// timeout, alreadyExists, isADirectory, notADirectory, directoryNotEmpty,
    /// io, and any SFTP `errorStatus`) is a real or non-transient failure and is
    /// deliberately NOT retried.
    private func isConnectionDead(_ error: Error) -> Bool {
        if case RemoteFSError.connectionLost = error { return true }
        if case SFTPError.connectionClosed = error { return true }
        if let ce = error as? ChannelError {
            switch ce {
            case .ioOnClosedChannel, .alreadyClosed, .eof: return true
            default: return false
            }
        }
        return false
    }

    private func connect() async throws -> SFTPClient {
        do {
            let client = try await SSHClient.connect(
                host: host,
                port: port,
                authenticationMethod: try makeAuthMethod(),
                hostKeyValidator: try makeHostKeyValidator(),
                reconnect: .never)
            let sftpClient = try await client.openSFTP()
            lock.withLock {
                self.ssh = client
                self.sftp = sftpClient
            }
            return sftpClient
        } catch let e as RemoteFSError {
            throw e
        } catch {
            // Distinguish auth rejection from a transport failure so the errno
            // mapping (EACCES vs EIO) and any UI message are meaningful.
            let text = String(describing: error).lowercased()
            if text.contains("auth") || text.contains("password") || text.contains("permission") {
                // Credential hygiene: the raw Citadel/NIOSSH error is DELIBERATELY
                // NOT included in the message. On the auth path that underlying
                // error could embed the attempted password (or other credential
                // material), so we surface a fixed, non-error-derived string. Do
                // not change this to interpolate `error` — it would risk leaking a
                // credential into logs/UI.
                throw RemoteFSError.authenticationFailed("SSH authentication rejected by server")
            }
            throw RemoteFSError.connectionLost
        }
    }

    /// Return the live SFTP client, or establish one — coalescing concurrent
    /// callers onto a single in-flight connect so we never open a redundant
    /// SSH session or orphan a client. The lock is released before awaiting the
    /// Task (never held across `await`).
    private func liveOrConnect() async throws -> SFTPClient {
        if let live = liveSFTP() { return live }
        let task: Task<SFTPClient, Error> = lock.withLock {
            if let existing = connectingTask { return existing }
            let t = Task { try await self.connect() }
            connectingTask = t
            return t
        }
        do {
            let client = try await task.value
            lock.withLock { if connectingTask == task { connectingTask = nil } }
            return client
        } catch {
            lock.withLock { if connectingTask == task { connectingTask = nil } }
            throw error
        }
    }

    /// Run an SFTP operation against a live channel, connecting first if needed.
    ///
    /// If the operation fails because the transport died (see `isConnectionDead`),
    /// drop the client, reconnect ONCE, and retry the operation a single time. A
    /// failure on the retry propagates unchanged. Non-transport errors are never
    /// retried.
    public func withSFTP<T: Sendable>(_ body: @Sendable (SFTPClient) async throws -> T) async throws -> T {
        let client = try await liveOrConnect()
        do {
            return try await body(client)
        } catch {
            guard isConnectionDead(error) else { throw error }
            dropClient()
            let fresh = try await liveOrConnect()
            return try await body(fresh)
        }
    }

    /// Best-effort teardown of the current client so the next call reconnects.
    ///
    /// Used when a caller (e.g. `SFTPFileSystem` on `RemoteFSError.timeout`)
    /// suspects the connection is wedged. Citadel/NIOSSH calls may not observe
    /// Swift Task cancellation, so a `withTimeout` that fires does NOT guarantee
    /// the underlying SFTP request stopped — leaving a possibly-half-wedged
    /// client that `liveSFTP()` would otherwise happily reuse. Proactively drop
    /// (and try to close) it here so a wedged connection is never silently reused.
    public func invalidate() async {
        let s: SSHClient?
        let f: SFTPClient?
        (s, f) = lock.withLock {
            let pair = (ssh, sftp)
            ssh = nil
            sftp = nil
            return pair
        }
        try? await f?.close()
        try? await s?.close()
    }

    public func close() async {
        let s: SSHClient?
        let f: SFTPClient?
        (s, f) = lock.withLock {
            let pair = (ssh, sftp)
            ssh = nil
            sftp = nil
            return pair
        }
        try? await f?.close()
        try? await s?.close()
    }
}
