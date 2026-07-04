import Foundation

public struct ConnectionConfig: Codable, Hashable, Sendable, Identifiable {
    public enum Auth: Codable, Hashable, Sendable {
        /// Password lives in the SecretStore (Keychain), never here.
        case password
        /// Key file referenced by path; passphrase (if any) in the SecretStore.
        case privateKey(path: String)
    }

    public var id: UUID
    public var name: String
    public var host: String
    public var port: Int
    public var username: String
    public var auth: Auth
    public var remotePath: String
    public var volumeName: String

    public init(id: UUID, name: String, host: String, port: Int, username: String,
                auth: Auth, remotePath: String, volumeName: String) {
        self.id = id
        self.name = name
        self.host = host
        self.port = port
        self.username = username
        self.auth = auth
        self.remotePath = remotePath
        self.volumeName = volumeName
    }
}
