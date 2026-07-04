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

    /// Upserts by delete-then-add. Not atomic: two concurrent setSecret calls for
    /// the same (id, kind) can race, with one failing as errSecDuplicateItem
    /// (surfaced as SecretStoreError.keychain). Callers serialize writes per
    /// connection, so this is not hit in practice.
    public func setSecret(_ value: String, kind: SecretKind, for id: UUID) throws {
        var q = query(kind, id)
        SecItemDelete(q as CFDictionary)  // upsert: ignore result
        q[kSecValueData as String] = Data(value.utf8)
        // AfterFirstUnlock (not WhenUnlocked): the FSKit extension may need to
        // read SSH credentials to remount headless/at boot or while the screen
        // is locked. Trade-off: secrets remain readable after the first unlock
        // post-boot until shutdown — acceptable for a background mount daemon.
        q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        let status = SecItemAdd(q as CFDictionary, nil)
        guard status == errSecSuccess else { throw SecretStoreError.keychain(status) }
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
