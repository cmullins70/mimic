import Foundation
import VFSCore
import CacheLayer
import SFTPBackend

// Usage:
//   mimic-cli ls  sftp://user:password@host:port/root [subpath]
//   mimic-cli cat sftp://user:password@host:port/root <file>
//   mimic-cli put sftp://user:password@host:port/root <localfile> <remotepath>
//
// Password in the URL is for smoke testing ONLY (throwaway fixture server);
// real credential handling (Keychain) arrives with the app in Plan 2. Host keys
// are accepted unconditionally here — do not point this at an untrusted server.

@main
struct MimicCLI {
    static func main() async {
        do { try await run() } catch {
            FileHandle.standardError.write(Data("error: \(error)\n".utf8))
            exit(1)
        }
    }

    static func run() async throws {
        let args = CommandLine.arguments
        guard args.count >= 3, let url = URL(string: args[2]), url.scheme == "sftp",
              let host = url.host, let user = url.user, let password = url.password else {
            print("usage: mimic-cli <ls|cat|put> sftp://user:pass@host:port/root [args]")
            exit(2)
        }
        let fs = try await SFTPFileSystem.connect(
            host: host, port: url.port ?? 22, username: user,
            auth: .password(password), hostKeyPolicy: .acceptAny, root: url.path)

        let cacheDir = FileManager.default.temporaryDirectory.appendingPathComponent("mimic-cli-cache")
        let cached = try CachedFS(
            backend: fs, connectionID: "cli",
            chunkCache: ChunkCache(directory: cacheDir, byteLimit: 256 * 1024 * 1024),
            metadataCache: MetadataCache())

        switch args[1] {
        case "ls":
            let dir = try RemotePath(args.count > 3 ? args[3] : "/")
            for e in try await cached.list(directory: dir) {
                let flag = e.attributes.type == .directory ? "d" : "-"
                print("\(flag) \(String(format: "%10d", e.attributes.size)) \(e.name)")
            }
        case "cat":
            let p = try RemotePath(args[3])
            let attrs = try await cached.attributes(at: p)
            let data = try await cached.read(file: p, offset: 0, length: Int(attrs.size))
            FileHandle.standardOutput.write(data)
        case "put":
            let local = URL(fileURLWithPath: args[3])
            let remote = try RemotePath(args[4])
            let data = try Data(contentsOf: local)
            try? await cached.createFile(at: remote)
            try await cached.write(file: remote, offset: 0, data: data)
            print("wrote \(data.count) bytes to \(remote)")
        default:
            print("unknown command \(args[1])")
            exit(2)
        }
    }
}
