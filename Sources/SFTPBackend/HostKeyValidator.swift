import Foundation
import Citadel
import NIOCore
import NIOSSH
import Crypto
import VFSCore

/// Trust-on-first-use host-key validator for Citadel's `.custom(_:)` hook.
///
/// Computes the server key's OpenSSH `SHA256:` fingerprint and consults a
/// `HostKeyStore`. It FAILS CLOSED: an unknown key (first contact) and a changed
/// key (MITM signal) both reject the connection with `RemoteFSError.hostKeyMismatch`
/// carrying the actual fingerprint, so the caller can prompt the user and, only
/// after out-of-band confirmation, call `HostKeyStore.trust` and reconnect.
///
/// The failure error propagates unwrapped up through Citadel's `SSHClient.connect`,
/// so callers can `catch let e as RemoteFSError` at the connect site.
struct TOFUHostKeyValidator: NIOSSHClientServerAuthenticationDelegate {
    let store: HostKeyStore
    let host: String
    let port: Int

    func validateHostKey(hostKey: NIOSSHPublicKey, validationCompletePromise: EventLoopPromise<Void>) {
        let fp = Self.fingerprint(of: hostKey)
        switch store.check(host: host, port: port, fingerprint: fp) {
        case .trusted:
            validationCompletePromise.succeed(())
        case .unknown:
            validationCompletePromise.fail(RemoteFSError.hostKeyMismatch(expected: "", actual: fp))
        case .mismatch(let expected):
            validationCompletePromise.fail(RemoteFSError.hostKeyMismatch(expected: expected, actual: fp))
        }
    }

    /// OpenSSH-style `SHA256:<unpadded-base64>` over the SSH wire encoding of the
    /// public key — the exact bytes `ssh-keygen -lf` / `known_hosts` hash.
    static func fingerprint(of key: NIOSSHPublicKey) -> String {
        var buf = ByteBufferAllocator().buffer(capacity: 256)
        key.write(to: &buf)
        let digest = SHA256.hash(data: Data(buf.readableBytesView))
        let b64 = Data(digest).base64EncodedString().replacingOccurrences(of: "=", with: "")
        return "SHA256:" + b64
    }
}
