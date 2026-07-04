import Foundation

/// Persists connection configs as one JSON file (0600) in the given directory.
/// In production the directory is the app-group container so the FSKit
/// extension can read it; tests use a temp dir.
public final class ConnectionStore: @unchecked Sendable {
    private let fileURL: URL
    private let lock = NSLock()

    public init(directory: URL) {
        self.fileURL = directory.appendingPathComponent("connections.json")
    }

    public func all() throws -> [ConnectionConfig] {
        lock.withLock { loadUnlocked() }
    }

    public func connection(id: UUID) throws -> ConnectionConfig? {
        try all().first { $0.id == id }
    }

    public func save(_ config: ConnectionConfig) throws {
        try lock.withLock {
            var configs = loadUnlocked()
            configs.removeAll { $0.id == config.id }
            configs.append(config)
            try writeUnlocked(configs)
        }
    }

    public func delete(id: UUID) throws {
        try lock.withLock {
            var configs = loadUnlocked()
            configs.removeAll { $0.id == id }
            try writeUnlocked(configs)
        }
    }

    /// Callers must hold `lock`.
    private func loadUnlocked() -> [ConnectionConfig] {
        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        return (try? JSONDecoder().decode([ConnectionConfig].self, from: data)) ?? []
    }

    /// Callers must hold `lock`.
    private func writeUnlocked(_ configs: [ConnectionConfig]) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(configs)
        try data.write(to: fileURL, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o600))], ofItemAtPath: fileURL.path)
    }
}
