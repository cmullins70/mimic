import Foundation

public enum HostKeyStoreError: Error, Equatable, Sendable {
    case corruptStore(String)
    case wouldReplaceExistingKey(expected: String)
}

/// Trust-on-first-use host key store. Fingerprints are OpenSSH-style
/// "SHA256:<base64>" strings. Persisted as JSON (0600).
///
/// This is a MITM guard, so it fails closed: a missing file is a normal first
/// run (empty store), but a file that exists yet cannot be read or decoded
/// throws `HostKeyStoreError.corruptStore` at init rather than silently
/// forgetting every pin and re-TOFU-trusting the next host. `trust` refuses to
/// overwrite an existing pin with a different key (throws
/// `wouldReplaceExistingKey`); changing a pin requires the explicit
/// `replacePin`, so an accidental clobber of the MITM signal is impossible.
public final class HostKeyStore: @unchecked Sendable {
    public enum Verdict: Equatable, Sendable {
        case trusted
        case unknown
        case mismatch(expected: String)
    }

    private let fileURL: URL
    private let lock = NSLock()
    private var entries: [String: String]  // "host:port" → fingerprint

    public init(fileURL: URL) throws {
        self.fileURL = fileURL
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            entries = [:]
            return
        }
        let data: Data
        do {
            data = try Data(contentsOf: fileURL)
        } catch {
            throw HostKeyStoreError.corruptStore("unreadable known-hosts file: \(error)")
        }
        do {
            entries = try JSONDecoder().decode([String: String].self, from: data)
        } catch {
            throw HostKeyStoreError.corruptStore("undecodable known-hosts file: \(error)")
        }
    }

    // "host:port" opaque key: host is lowercased for case-insensitive match.
    // Assumes host is not a bracketed IPv6 literal; the key is never re-parsed
    // in v1, so an embedded colon is harmless (acceptable, documented).
    private static func key(_ host: String, _ port: Int) -> String { "\(host.lowercased()):\(port)" }

    public func check(host: String, port: Int, fingerprint: String) -> Verdict {
        lock.withLock {
            guard let known = entries[Self.key(host, port)] else { return .unknown }
            return known == fingerprint ? .trusted : .mismatch(expected: known)
        }
    }

    /// Pins a host key on first use. Idempotent for an identical existing pin.
    /// Throws `wouldReplaceExistingKey` if a *different* key is already pinned —
    /// use `replacePin` to deliberately change a pin after verifying the change.
    public func trust(host: String, port: Int, fingerprint: String) throws {
        try lock.withLock {
            let k = Self.key(host, port)
            if let existing = entries[k] {
                if existing == fingerprint { return }  // idempotent no-op
                throw HostKeyStoreError.wouldReplaceExistingKey(expected: existing)
            }
            entries[k] = fingerprint
            try persistUnlocked()
        }
    }

    /// Deliberately overwrites an existing pin. The only path that may change a
    /// key already trusted — callers must have verified the new key out of band.
    public func replacePin(host: String, port: Int, fingerprint: String) throws {
        try lock.withLock {
            entries[Self.key(host, port)] = fingerprint
            try persistUnlocked()
        }
    }

    /// Callers must hold `lock`.
    private func persistUnlocked() throws {
        let data = try JSONEncoder().encode(entries)
        try data.write(to: fileURL, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o600))], ofItemAtPath: fileURL.path)
    }
}
