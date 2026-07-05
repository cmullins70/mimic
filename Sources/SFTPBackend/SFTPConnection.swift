import Foundation
import Citadel
import VFSCore

public enum SFTPAuth: Sendable {
    case password(String)
    case privateKey(path: String, passphrase: String?)
}

public enum HostKeyPolicy: Sendable {
    /// Accepts any host key. Test fixtures / throwaway localhost servers ONLY.
    case acceptAny
    /// Trust-on-first-use backed by `HostKeyStore`. NOT yet implemented — fails
    /// closed (see `makeHostKeyValidator`). Wiring it requires computing the
    /// server's SHA256 fingerprint from swift-nio-ssh's `NIOSSHPublicKey`.
    case tofu(HostKeyStore)
}

/// Owns one Citadel `SSHClient` + `SFTPClient` for a single server.
///
/// Citadel's `SSHClient` and `SSHAuthenticationMethod` are non-Sendable, so this
/// wrapper is `@unchecked Sendable`: the mutable client refs are guarded by
/// `lock` (held only for synchronous get/set, never across `await`), and the
/// actual SFTP I/O runs on Citadel's own thread-safe, `Sendable` `SFTPClient`.
/// Callers drive one logical connection sequentially (the CLI and the
/// integration tests do); concurrent first-use could open a redundant session.
public final class SFTPConnection: @unchecked Sendable {
    public let host: String
    public let port: Int
    public let username: String
    private let auth: SFTPAuth
    private let hostKeyPolicy: HostKeyPolicy

    private let lock = NSLock()
    private var ssh: SSHClient?
    private var sftp: SFTPClient?

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
        case .tofu:
            // Fail closed: NEVER silently accept an unverified host key under a
            // policy whose whole purpose is MITM protection. Real TOFU (compute
            // SHA256 fingerprint from NIOSSHPublicKey, consult HostKeyStore) is a
            // tracked follow-up.
            throw RemoteFSError.unsupported("TOFU host-key verification not implemented yet")
        }
    }

    private func liveSFTP() -> SFTPClient? {
        lock.withLock {
            if let s = sftp, s.isActive { return s }
            return nil
        }
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
                throw RemoteFSError.authenticationFailed(String(describing: error))
            }
            throw RemoteFSError.connectionLost
        }
    }

    /// Run an SFTP operation against a live channel, connecting first if needed.
    public func withSFTP<T: Sendable>(_ body: @Sendable (SFTPClient) async throws -> T) async throws -> T {
        let client: SFTPClient
        if let existing = liveSFTP() {
            client = existing
        } else {
            client = try await connect()
        }
        return try await body(client)
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
