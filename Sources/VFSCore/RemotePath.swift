/// A normalized, absolute path inside a remote volume. Always starts with "/",
/// never ends with "/" (except root), no "." or ".." or empty components.
public struct RemotePath: Hashable, Sendable, Codable, CustomStringConvertible {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public var description: String { rawValue }
}
