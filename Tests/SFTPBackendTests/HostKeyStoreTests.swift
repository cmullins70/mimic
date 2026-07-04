import Testing
import Foundation
@testable import SFTPBackend

private func tempFile() -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("mimic-hosts-\(UUID().uuidString).json")
}

@Test func firstUseIsUnknownThenTrustPersists() throws {
    let url = tempFile()
    let store = try HostKeyStore(fileURL: url)
    #expect(store.check(host: "example.com", port: 22, fingerprint: "SHA256:abc") == .unknown)

    try store.trust(host: "example.com", port: 22, fingerprint: "SHA256:abc")
    #expect(store.check(host: "example.com", port: 22, fingerprint: "SHA256:abc") == .trusted)

    let reloaded = try HostKeyStore(fileURL: url)
    #expect(reloaded.check(host: "example.com", port: 22, fingerprint: "SHA256:abc") == .trusted)
}

@Test func changedKeyIsMismatch() throws {
    let store = try HostKeyStore(fileURL: tempFile())
    try store.trust(host: "h", port: 22, fingerprint: "SHA256:old")
    #expect(store.check(host: "h", port: 22, fingerprint: "SHA256:NEW") == .mismatch(expected: "SHA256:old"))
}

@Test func samePortDifferentHostIndependent() throws {
    let store = try HostKeyStore(fileURL: tempFile())
    try store.trust(host: "a", port: 22, fingerprint: "SHA256:x")
    #expect(store.check(host: "b", port: 22, fingerprint: "SHA256:x") == .unknown)
}

@Test func corruptKnownHostsFileThrowsAtInit() throws {
    let url = tempFile()
    try Data([0xDE, 0xAD, 0xBE, 0xEF]).write(to: url)
    #expect(throws: HostKeyStoreError.self) {
        _ = try HostKeyStore(fileURL: url)
    }
}

@Test func missingFileIsEmptyNoThrow() throws {
    let store = try HostKeyStore(fileURL: tempFile())
    #expect(store.check(host: "example.com", port: 22, fingerprint: "SHA256:abc") == .unknown)
}

@Test func trustRefusesToOverwriteDifferentKey() throws {
    let store = try HostKeyStore(fileURL: tempFile())
    try store.trust(host: "h", port: 22, fingerprint: "SHA256:a")

    #expect(throws: HostKeyStoreError.wouldReplaceExistingKey(expected: "SHA256:a")) {
        try store.trust(host: "h", port: 22, fingerprint: "SHA256:b")
    }
    // Old pin intact after the refused overwrite.
    #expect(store.check(host: "h", port: 22, fingerprint: "SHA256:a") == .trusted)

    try store.replacePin(host: "h", port: 22, fingerprint: "SHA256:b")
    #expect(store.check(host: "h", port: 22, fingerprint: "SHA256:b") == .trusted)
}

@Test func trustIsIdempotentForSameKey() throws {
    let store = try HostKeyStore(fileURL: tempFile())
    try store.trust(host: "h", port: 22, fingerprint: "SHA256:a")
    try store.trust(host: "h", port: 22, fingerprint: "SHA256:a")  // no throw
    #expect(store.check(host: "h", port: 22, fingerprint: "SHA256:a") == .trusted)
}

@Test func hostLookupIsCaseInsensitive() throws {
    let store = try HostKeyStore(fileURL: tempFile())
    try store.trust(host: "Example.COM", port: 22, fingerprint: "SHA256:a")
    #expect(store.check(host: "example.com", port: 22, fingerprint: "SHA256:a") == .trusted)
}
