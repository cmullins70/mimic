import Testing
import Foundation
@testable import SFTPBackend

private func tempFile() -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("mimic-hosts-\(UUID().uuidString).json")
}

@Test func firstUseIsUnknownThenTrustPersists() throws {
    let url = tempFile()
    let store = HostKeyStore(fileURL: url)
    #expect(store.check(host: "example.com", port: 22, fingerprint: "SHA256:abc") == .unknown)

    try store.trust(host: "example.com", port: 22, fingerprint: "SHA256:abc")
    #expect(store.check(host: "example.com", port: 22, fingerprint: "SHA256:abc") == .trusted)

    let reloaded = HostKeyStore(fileURL: url)
    #expect(reloaded.check(host: "example.com", port: 22, fingerprint: "SHA256:abc") == .trusted)
}

@Test func changedKeyIsMismatch() throws {
    let store = HostKeyStore(fileURL: tempFile())
    try store.trust(host: "h", port: 22, fingerprint: "SHA256:old")
    #expect(store.check(host: "h", port: 22, fingerprint: "SHA256:NEW") == .mismatch(expected: "SHA256:old"))
}

@Test func samePortDifferentHostIndependent() throws {
    let store = HostKeyStore(fileURL: tempFile())
    try store.trust(host: "a", port: 22, fingerprint: "SHA256:x")
    #expect(store.check(host: "b", port: 22, fingerprint: "SHA256:x") == .unknown)
}
