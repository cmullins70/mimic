public enum RemotePathError: Error, Equatable, Sendable {
    case notAbsolute(String)
    case invalidComponent(String)
}

/// A normalized, absolute path inside a remote volume. Always starts with "/",
/// never ends with "/" (except root), no "." / ".." / empty components.
public struct RemotePath: Hashable, Sendable, Codable, CustomStringConvertible {
    public let rawValue: String

    public init(rawValue: String) { self.rawValue = rawValue }

    public init(_ string: String) throws {
        guard string.hasPrefix("/") else { throw RemotePathError.notAbsolute(string) }
        let components = string.split(separator: "/", omittingEmptySubsequences: true)
        for c in components where c == "." || c == ".." {
            throw RemotePathError.invalidComponent(String(c))
        }
        self.rawValue = components.isEmpty ? "/" : "/" + components.joined(separator: "/")
    }

    public static let root = RemotePath(rawValue: "/")

    /// Last path component; "/" for root.
    public var name: String {
        rawValue == "/" ? "/" : String(rawValue.split(separator: "/").last!)
    }

    /// nil for root.
    public var parent: RemotePath? {
        guard rawValue != "/" else { return nil }
        let comps = rawValue.split(separator: "/").dropLast()
        return RemotePath(rawValue: comps.isEmpty ? "/" : "/" + comps.joined(separator: "/"))
    }

    public func appending(_ component: String) -> RemotePath {
        RemotePath(rawValue: rawValue == "/" ? "/\(component)" : "\(rawValue)/\(component)")
    }

    public var description: String { rawValue }
}
