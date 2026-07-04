import Foundation

/// Reference RemoteFS used by tests, CacheLayer tests, and mimic-cli --demo.
/// Actor for trivial thread safety; performance is irrelevant here.
public actor InMemoryFS: RemoteFS {
    private enum Node {
        case file(Data, modified: Date)
        case directory(modified: Date)
    }

    private var nodes: [RemotePath: Node] = [.root: .directory(modified: .now)]

    public init() {}

    private func node(_ p: RemotePath) throws -> Node {
        guard let n = nodes[p] else { throw RemoteFSError.notFound(p) }
        return n
    }

    private func requireParentDirectory(of p: RemotePath) throws {
        guard let parent = p.parent else { throw RemoteFSError.alreadyExists(p) } // root
        guard case .directory = try node(parent) else { throw RemoteFSError.notADirectory(parent) }
    }

    private func attributes(for node: Node) -> FileAttributes {
        switch node {
        case .file(let d, let m):
            FileAttributes(type: .file, size: UInt64(d.count), modified: m, permissions: 0o644)
        case .directory(let m):
            FileAttributes(type: .directory, size: 0, modified: m, permissions: 0o755)
        }
    }

    public func attributes(at path: RemotePath) async throws -> FileAttributes {
        attributes(for: try node(path))
    }

    public func list(directory: RemotePath) async throws -> [DirEntry] {
        guard case .directory = try node(directory) else {
            throw RemoteFSError.notADirectory(directory)
        }
        var out: [DirEntry] = []
        for (p, n) in nodes where p.parent == directory {
            out.append(DirEntry(name: p.name, attributes: attributes(for: n)))
        }
        return out.sorted { $0.name < $1.name }
    }

    public func read(file: RemotePath, offset: UInt64, length: Int) async throws -> Data {
        guard case .file(let d, _) = try node(file) else { throw RemoteFSError.isADirectory(file) }
        let start = min(Int(offset), d.count)
        let end = min(start + length, d.count)
        return d.subdata(in: start..<end)
    }

    public func write(file: RemotePath, offset: UInt64, data: Data) async throws {
        guard case .file(var d, _) = try node(file) else { throw RemoteFSError.isADirectory(file) }
        let off = Int(offset)
        if d.count < off { d.append(Data(repeating: 0, count: off - d.count)) }
        if off + data.count <= d.count {
            d.replaceSubrange(off..<(off + data.count), with: data)
        } else {
            d = Data(d.prefix(off)) + data
        }
        nodes[file] = .file(d, modified: .now)
    }

    public func createFile(at path: RemotePath) async throws {
        guard nodes[path] == nil else { throw RemoteFSError.alreadyExists(path) }
        try requireParentDirectory(of: path)
        nodes[path] = .file(Data(), modified: .now)
    }

    public func createDirectory(at path: RemotePath) async throws {
        guard nodes[path] == nil else { throw RemoteFSError.alreadyExists(path) }
        try requireParentDirectory(of: path)
        nodes[path] = .directory(modified: .now)
    }

    public func removeFile(at path: RemotePath) async throws {
        guard case .file = try node(path) else { throw RemoteFSError.isADirectory(path) }
        nodes[path] = nil
    }

    public func removeDirectory(at path: RemotePath) async throws {
        guard case .directory = try node(path) else { throw RemoteFSError.notADirectory(path) }
        guard !nodes.keys.contains(where: { $0.parent == path }) else {
            throw RemoteFSError.directoryNotEmpty(path)
        }
        nodes[path] = nil
    }

    public func rename(from: RemotePath, to: RemotePath) async throws {
        _ = try node(from)
        guard nodes[to] == nil else { throw RemoteFSError.alreadyExists(to) }
        try requireParentDirectory(of: to)
        let moving = nodes.keys.filter { $0 == from || $0.rawValue.hasPrefix(from.rawValue + "/") }
        for old in moving {
            let suffix = String(old.rawValue.dropFirst(from.rawValue.count))
            let new = RemotePath(rawValue: to.rawValue + suffix)
            nodes[new] = nodes.removeValue(forKey: old)
        }
    }

    public func truncate(file: RemotePath, to size: UInt64) async throws {
        guard case .file(var d, _) = try node(file) else { throw RemoteFSError.isADirectory(file) }
        if d.count > Int(size) {
            d = Data(d.prefix(Int(size)))
        } else {
            d.append(Data(repeating: 0, count: Int(size) - d.count))
        }
        nodes[file] = .file(d, modified: .now)
    }
}
