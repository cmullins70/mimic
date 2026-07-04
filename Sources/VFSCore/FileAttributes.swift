import Foundation

public enum EntryType: String, Sendable, Codable, Hashable {
    case file, directory, symlink
}

public struct FileAttributes: Sendable, Codable, Hashable {
    public var type: EntryType
    public var size: UInt64
    public var modified: Date
    /// POSIX permission bits, e.g. 0o644.
    public var permissions: UInt16

    public init(type: EntryType, size: UInt64, modified: Date, permissions: UInt16) {
        self.type = type
        self.size = size
        self.modified = modified
        self.permissions = permissions
    }
}

public struct DirEntry: Sendable, Codable, Hashable {
    public var name: String
    public var attributes: FileAttributes

    public init(name: String, attributes: FileAttributes) {
        self.name = name
        self.attributes = attributes
    }
}
