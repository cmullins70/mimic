import Testing
import Foundation
import VFSCore
@testable import SFTPBackend

// Integration tests against the Task 11 fixture. Auto-skipped unless
// MIMIC_SFTP_TEST_HOST is set, so plain `swift test` stays green everywhere.
//
// Run with:  scripts/sftp-test-server.sh start
//            MIMIC_SFTP_TEST_HOST=localhost swift test --filter SFTPIntegration
private var enabled: Bool { ProcessInfo.processInfo.environment["MIMIC_SFTP_TEST_HOST"] != nil }

private func makeFS() async throws -> SFTPFileSystem {
    let host = ProcessInfo.processInfo.environment["MIMIC_SFTP_TEST_HOST"]!
    return try await SFTPFileSystem.connect(
        host: host, port: 2222, username: "mimic",
        auth: .password("mimictest"),
        hostKeyPolicy: .acceptAny,   // test fixture only; real callers use .tofu(HostKeyStore)
        root: "/upload")
}

@Test(.enabled(if: enabled)) func fullFileLifecycle() async throws {
    let fs = try await makeFS()
    let p = try RemotePath("/it-\(UUID().uuidString).txt")
    try await fs.createFile(at: p)
    try await fs.write(file: p, offset: 0, data: Data("integration".utf8))
    #expect(try await fs.attributes(at: p).size == 11)
    let d = try await fs.read(file: p, offset: 6, length: 5)
    #expect(String(decoding: d, as: UTF8.self) == "ation")
    try await fs.removeFile(at: p)
    await #expect(throws: RemoteFSError.notFound(p)) { _ = try await fs.attributes(at: p) }
}

@Test(.enabled(if: enabled)) func directoryLifecycleAndListing() async throws {
    let fs = try await makeFS()
    let dir = try RemotePath("/dir-\(UUID().uuidString)")
    try await fs.createDirectory(at: dir)
    try await fs.createFile(at: dir.appending("a.txt"))
    try await fs.createFile(at: dir.appending("b.txt"))
    let names = try await fs.list(directory: dir).map(\.name).sorted()
    #expect(names == ["a.txt", "b.txt"])
    try await fs.removeFile(at: dir.appending("a.txt"))
    try await fs.removeFile(at: dir.appending("b.txt"))
    try await fs.removeDirectory(at: dir)
}

@Test(.enabled(if: enabled)) func renameAndUnicode() async throws {
    let fs = try await makeFS()
    let a = try RemotePath("/héllo-\(UUID().uuidString).txt")
    let b = try RemotePath("/wörld-\(UUID().uuidString).txt")
    try await fs.createFile(at: a)
    try await fs.rename(from: a, to: b)
    _ = try await fs.attributes(at: b)
    try await fs.removeFile(at: b)
}

@Test(.enabled(if: enabled)) func largeFileChunkedReadback() async throws {
    let fs = try await makeFS()
    let p = try RemotePath("/big-\(UUID().uuidString).bin")
    let payload = Data((0..<(5 * 1024 * 1024)).map { UInt8($0 % 251) })  // 5 MB
    try await fs.createFile(at: p)
    try await fs.write(file: p, offset: 0, data: payload)
    #expect(try await fs.attributes(at: p).size == UInt64(payload.count))
    let middle = try await fs.read(file: p, offset: 3_000_000, length: 4096)
    #expect(middle == payload.subdata(in: 3_000_000..<3_004_096))
    try await fs.removeFile(at: p)
}

@Test(.enabled(if: enabled)) func wrongPasswordFailsCleanly() async throws {
    let host = ProcessInfo.processInfo.environment["MIMIC_SFTP_TEST_HOST"]!
    await #expect(throws: RemoteFSError.self) {
        _ = try await SFTPFileSystem.connect(
            host: host, port: 2222, username: "mimic",
            auth: .password("wrong"), hostKeyPolicy: .acceptAny, root: "/upload")
    }
}

// TOFU host-key verification: first contact fails closed carrying the server's
// fingerprint (UI would prompt + trust), a trusted key connects, and a changed
// key (MITM signal) fails with a mismatch. `SFTPIntegration` in the name so the
// existing filter picks it up.
@Test(.enabled(if: enabled)) func tofuHostKeySFTPIntegration() async throws {
    let host = ProcessInfo.processInfo.environment["MIMIC_SFTP_TEST_HOST"]!
    let storeFile = FileManager.default.temporaryDirectory
        .appendingPathComponent("mimic-known-hosts-\(UUID().uuidString).json")
    defer { try? FileManager.default.removeItem(at: storeFile) }
    let store = try HostKeyStore(fileURL: storeFile)

    func connectTOFU() async throws -> SFTPFileSystem {
        try await SFTPFileSystem.connect(
            host: host, port: 2222, username: "mimic", auth: .password("mimictest"),
            hostKeyPolicy: .tofu(store), root: "/upload")
    }

    // 1. Unknown host key on first contact → fails closed, surfacing the actual fp.
    let firstFingerprint: String
    do {
        _ = try await connectTOFU()
        Issue.record("expected hostKeyMismatch on first (unknown) contact")
        return
    } catch let RemoteFSError.hostKeyMismatch(expected, actual) {
        #expect(expected == "")                 // unknown ⇒ no prior pin
        #expect(actual.hasPrefix("SHA256:"))
        firstFingerprint = actual
    }

    // 2. Trust it (what the UI does after prompting) → reconnect succeeds.
    try store.trust(host: host, port: 2222, fingerprint: firstFingerprint)
    let fs = try await connectTOFU()
    _ = try await fs.list(directory: .root)

    // 3. Pin a different key (simulated MITM) → reconnect fails with a mismatch.
    try store.replacePin(host: host, port: 2222,
                         fingerprint: "SHA256:AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA")
    await #expect(throws: RemoteFSError.self) { _ = try await connectTOFU() }
}
