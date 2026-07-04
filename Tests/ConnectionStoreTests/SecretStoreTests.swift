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

// This test hits the real macOS Keychain and is skipped unless
// MIMIC_KEYCHAIN_TEST=1 is set, so local/dev runs don't touch the developer's
// keychain. CI (.github/workflows/ci.yml) sets that var and provisions a
// dedicated unlocked keychain, so this path is exercised there.
@Test(.enabled(if: ProcessInfo.processInfo.environment["MIMIC_KEYCHAIN_TEST"] == "1"))
func keychainRoundtrip() throws {
    let store = KeychainSecretStore(service: "io.mimic.test")
    let id = UUID()
    try store.setSecret("s3cret", kind: .password, for: id)
    #expect(try store.secret(kind: .password, for: id) == "s3cret")
    try store.deleteSecrets(for: id)
    #expect(try store.secret(kind: .password, for: id) == nil)
}

// Regression for the delete-then-add race. The original upsert (and even a
// single retry-on-duplicate) failed en masse with errSecDuplicateItem (-25299)
// under contention — ~160-183/200. The add-or-update implementation converges
// concurrent writers to last-writer-wins, so no call throws and the final value
// is one of the writes. Same keychain gate as above.
@Test(.enabled(if: ProcessInfo.processInfo.environment["MIMIC_KEYCHAIN_TEST"] == "1"))
func concurrentSetSecretForSameConnectionDoesNotRace() throws {
    let store = KeychainSecretStore(service: "io.mimic.test.concurrent")
    let id = UUID()
    defer { try? store.deleteSecrets(for: id) }

    let count = 200
    // Reference-type sink so the Sendable concurrentPerform closure can record
    // failures without mutating a captured var (Swift 6 strict concurrency).
    final class ErrorSink: @unchecked Sendable {
        private let lock = NSLock()
        private(set) var errors: [Error] = []
        func record(_ error: Error) { lock.withLock { errors.append(error) } }
    }
    let sink = ErrorSink()

    DispatchQueue.concurrentPerform(iterations: count) { i in
        do {
            try store.setSecret("v\(i)", kind: .password, for: id)
        } catch {
            sink.record(error)
        }
    }

    #expect(sink.errors.isEmpty, "concurrent setSecret threw: \(sink.errors)")
    let final = try store.secret(kind: .password, for: id)
    #expect(final != nil)
    #expect((0..<count).map { "v\($0)" }.contains(final ?? ""))
}
