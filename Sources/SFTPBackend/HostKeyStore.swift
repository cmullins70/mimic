import Foundation

/// Trust-on-first-use host key store. Fingerprints are OpenSSH-style
/// "SHA256:<base64>" strings. Persisted as JSON (0600).
public final class HostKeyStore: @unchecked Sendable {
    public enum Verdict: Equatable, Sendable {
        case trusted
        case unknown
        case mismatch(expected: String)
    }

    private let fileURL: URL
    private let lock = NSLock()
    private var entries: [String: String]  // "host:port" → fingerprint

    public init(fileURL: URL) {
        self.fileURL = fileURL
        if let data = try? Data(contentsOf: fileURL),
           let decoded = try? JSONDecoder().decode([String: String].self, from: data) {
            entries = decoded
        } else {
            entries = [:]
        }
    }

    private static func key(_ host: String, _ port: Int) -> String { "\(host.lowercased()):\(port)" }

    public func check(host: String, port: Int, fingerprint: String) -> Verdict {
        lock.withLock {
            guard let known = entries[Self.key(host, port)] else { return .unknown }
            return known == fingerprint ? .trusted : .mismatch(expected: known)
        }
    }

    public func trust(host: String, port: Int, fingerprint: String) throws {
        try lock.withLock {
            entries[Self.key(host, port)] = fingerprint
            let data = try JSONEncoder().encode(entries)
            try data.write(to: fileURL, options: .atomic)
            try FileManager.default.setAttributes(
                [.posixPermissions: NSNumber(value: Int16(0o600))], ofItemAtPath: fileURL.path)
        }
    }
}
