import Foundation
import Security

public enum SecretKind: String, Sendable {
    case password
    case keyPassphrase
}

public enum SecretStoreError: Error, Equatable, Sendable {
    case keychain(OSStatus)
}

public protocol SecretStore: Sendable {
    /// Upserts the secret for `(connectionID, kind)`.
    ///
    /// Concurrent calls for the same `(connectionID, kind)` are safe: the
    /// implementations converge to last-writer-wins without throwing
    /// (`InMemorySecretStore` via a lock, `KeychainSecretStore` via keychain
    /// add-or-update). The store does not, however, define *which* concurrent
    /// writer wins — serialize per `connectionID` upstream (e.g. via an actor or
    /// a per-ID queue) if you need a deterministic result, and note that a write
    /// racing `deleteSecrets(for:)` for the same id is still order-dependent.
    func setSecret(_ value: String, kind: SecretKind, for connectionID: UUID) throws
    func secret(kind: SecretKind, for connectionID: UUID) throws -> String?
    func deleteSecrets(for connectionID: UUID) throws
}

public final class InMemorySecretStore: SecretStore, @unchecked Sendable {
    private var storage: [String: String] = [:]
    private let lock = NSLock()
    public init() {}

    public func setSecret(_ value: String, kind: SecretKind, for id: UUID) throws {
        lock.withLock { storage["\(id.uuidString)/\(kind.rawValue)"] = value }
    }
    public func secret(kind: SecretKind, for id: UUID) throws -> String? {
        lock.withLock { storage["\(id.uuidString)/\(kind.rawValue)"] }
    }
    public func deleteSecrets(for id: UUID) throws {
        lock.withLock {
            storage = storage.filter { !$0.key.hasPrefix(id.uuidString + "/") }
        }
    }
}

/// Generic-password keychain items: service = <service>, account = <uuid>/<kind>.
/// In Plan 2 the app and extension share these via a keychain access group;
/// the `service` string stays the same.
public struct KeychainSecretStore: SecretStore {
    public let service: String
    public init(service: String = "io.mimic.secrets") { self.service = service }

    private func query(_ kind: SecretKind, _ id: UUID) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: "\(id.uuidString)/\(kind.rawValue)"]
    }

    /// Upserts via add-or-update: try SecItemAdd, and on errSecDuplicateItem fall
    /// back to SecItemUpdate of just the value data. Unlike delete-then-add this
    /// never removes the item, so there is no window where the secret momentarily
    /// disappears — the FSKit extension may be reading it cross-process — and
    /// concurrent setSecret calls for the same (id, kind) converge to
    /// last-writer-wins without any of them surfacing errSecDuplicateItem
    /// (OSStatus -25299). A delete-then-add + single retry does NOT hold under
    /// contention: a 200-way concurrent stress test still failed ~160/200, since
    /// the retried add races the same way (see SecretStoreTests).
    public func setSecret(_ value: String, kind: SecretKind, for id: UUID) throws {
        let data = Data(value.utf8)
        var attrs = query(kind, id)
        attrs[kSecValueData as String] = data
        // AfterFirstUnlock (not WhenUnlocked): the FSKit extension may need to
        // read SSH credentials to remount headless/at boot or while the screen
        // is locked. Trade-off: secrets remain readable after the first unlock
        // post-boot until shutdown — acceptable for a background mount daemon.
        // Only applied on insert; SecItemUpdate below leaves accessibility as-is,
        // which is fine because every insert uses this same value.
        attrs[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock

        let addStatus = SecItemAdd(attrs as CFDictionary, nil)
        switch addStatus {
        case errSecSuccess:
            return
        case errSecDuplicateItem:
            let updateStatus = SecItemUpdate(
                query(kind, id) as CFDictionary,
                [kSecValueData as String: data] as CFDictionary)
            guard updateStatus == errSecSuccess else { throw SecretStoreError.keychain(updateStatus) }
        default:
            throw SecretStoreError.keychain(addStatus)
        }
    }

    public func secret(kind: SecretKind, for id: UUID) throws -> String? {
        var q = query(kind, id)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            guard let data = result as? Data else { return nil }
            return String(decoding: data, as: UTF8.self)
        case errSecItemNotFound:
            return nil
        default:
            throw SecretStoreError.keychain(status)
        }
    }

    public func deleteSecrets(for id: UUID) throws {
        for kind in [SecretKind.password, .keyPassphrase] {
            let status = SecItemDelete(query(kind, id) as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else {
                throw SecretStoreError.keychain(status)
            }
        }
    }
}
