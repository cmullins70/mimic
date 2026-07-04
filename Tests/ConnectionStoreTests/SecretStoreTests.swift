import Testing
import Foundation
@testable import ConnectionStore

@Test func inMemoryRoundtripAndDelete() throws {
    let store = InMemorySecretStore()
    let id = UUID()
    try store.setSecret("hunter2", kind: .password, for: id)
    #expect(try store.secret(kind: .password, for: id) == "hunter2")
    try store.deleteSecrets(for: id)
    #expect(try store.secret(kind: .password, for: id) == nil)
}

@Test func kindsAreIndependent() throws {
    let store = InMemorySecretStore()
    let id = UUID()
    try store.setSecret("pw", kind: .password, for: id)
    try store.setSecret("phrase", kind: .keyPassphrase, for: id)
    #expect(try store.secret(kind: .password, for: id) == "pw")
    #expect(try store.secret(kind: .keyPassphrase, for: id) == "phrase")
}

@Test(.enabled(if: ProcessInfo.processInfo.environment["MIMIC_KEYCHAIN_TEST"] == "1"))
func keychainRoundtrip() throws {
    let store = KeychainSecretStore(service: "io.mimic.test")
    let id = UUID()
    try store.setSecret("s3cret", kind: .password, for: id)
    #expect(try store.secret(kind: .password, for: id) == "s3cret")
    try store.deleteSecrets(for: id)
    #expect(try store.secret(kind: .password, for: id) == nil)
}
