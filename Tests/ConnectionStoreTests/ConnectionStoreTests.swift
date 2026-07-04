import Testing
import Foundation
@testable import ConnectionStore

private func tempDir() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("mimic-conn-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

@Test func saveLoadRoundtrip() throws {
    let dir = try tempDir()
    let store = ConnectionStore(directory: dir)
    let config = ConnectionConfig(
        id: UUID(), name: "kyra-nest", host: "kyra-nest.tail1234.ts.net", port: 22,
        username: "chris", auth: .privateKey(path: "/Users/chris/.ssh/id_ed25519"),
        remotePath: "/data", volumeName: "KyraNest")
    try store.save(config)

    let reloaded = ConnectionStore(directory: dir)
    #expect(try reloaded.all() == [config])
    #expect(try reloaded.connection(id: config.id) == config)
}

@Test func deleteRemoves() throws {
    let store = ConnectionStore(directory: try tempDir())
    let c = ConnectionConfig(id: UUID(), name: "x", host: "h", port: 22,
                             username: "u", auth: .password, remotePath: "/", volumeName: "X")
    try store.save(c)
    try store.delete(id: c.id)
    #expect(try store.all().isEmpty)
}

@Test func configFilePermissionsAreOwnerOnly() throws {
    let dir = try tempDir()
    let store = ConnectionStore(directory: dir)
    let c = ConnectionConfig(id: UUID(), name: "x", host: "h", port: 22,
                             username: "u", auth: .password, remotePath: "/", volumeName: "X")
    try store.save(c)
    let file = dir.appendingPathComponent("connections.json")
    let perms = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as! NSNumber
    #expect(perms.uint16Value == 0o600)
}
