import Foundation

public enum ConnectionStoreError: Error, Equatable, Sendable {
    case corruptStore(String)
}

/// Persists connection configs as one JSON file (0600) in the given directory.
/// In production the directory is the app-group container so the FSKit
/// extension can read it; tests use a temp dir.
///
/// On-disk format is a versioned envelope: {"schemaVersion": 1, "connections": [...]}.
/// A missing file means an empty store; an unreadable or undecodable file throws
/// `ConnectionStoreError.corruptStore` so a subsequent save can never silently
/// destroy existing data.
public final class ConnectionStore: @unchecked Sendable {
    private static let schemaVersion = 1

    private struct Envelope: Codable {
        var schemaVersion: Int
        var connections: [ConnectionConfig]
    }

    private let fileURL: URL
    private let lock = NSLock()

    public init(directory: URL) {
        self.fileURL = directory.appendingPathComponent("connections.json")
    }

    public func all() throws -> [ConnectionConfig] {
        try lock.withLock { try loadUnlocked() }
    }

    public func connection(id: UUID) throws -> ConnectionConfig? {
        try all().first { $0.id == id }
    }

    public func save(_ config: ConnectionConfig) throws {
        try lock.withLock {
            var configs = try loadUnlocked()
            configs.removeAll { $0.id == config.id }
            configs.append(config)
            try writeUnlocked(configs)
        }
    }

    public func delete(id: UUID) throws {
        try lock.withLock {
            var configs = try loadUnlocked()
            configs.removeAll { $0.id == id }
            try writeUnlocked(configs)
        }
    }

    /// Callers must hold `lock`.
    private func loadUnlocked() throws -> [ConnectionConfig] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return [] }
        let data: Data
        do {
            data = try Data(contentsOf: fileURL)
        } catch {
            throw ConnectionStoreError.corruptStore("unreadable store file: \(error)")
        }
        let envelope: Envelope
        do {
            envelope = try JSONDecoder().decode(Envelope.self, from: data)
        } catch {
            throw ConnectionStoreError.corruptStore("undecodable store file: \(error)")
        }
        guard envelope.schemaVersion <= Self.schemaVersion else {
            throw ConnectionStoreError.corruptStore(
                "newer schema (\(envelope.schemaVersion)) than supported (\(Self.schemaVersion))")
        }
        return envelope.connections
    }

    /// Callers must hold `lock`.
    private func writeUnlocked(_ configs: [ConnectionConfig]) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(Envelope(schemaVersion: Self.schemaVersion, connections: configs))
        try data.write(to: fileURL, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o600))], ofItemAtPath: fileURL.path)
    }
}
