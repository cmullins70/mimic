# Mimic — Design Spec

**Date:** 2026-07-04
**Status:** Approved by Chris (brainstorming session 2026-07-04)
**Name:** Mimic — after the mimic octopus, which impersonates other animals. Mimic makes remote storage impersonate a local disk.

## 1. What Mimic is

A free, open-source macOS menu bar app that mounts remote storage as real Finder volumes using a **native FSKit extension** — no kernel extensions, no loopback NFS servers, no resident daemons. The first open-source FSKit network filesystem.

- **Platform:** macOS 26 (Tahoe) and later. FSKit's network-capable `FSGenericURLResource` requires macOS 26; programmatic mounting (`FSClient.mountSingleVolume`) additionally requires macOS 27.
- **v1 backend:** SFTP only.
- **Sync model:** live mount + local read cache. Writes pass through to the server. Offline means the volume is unavailable — no offline sync engine in v1.
- **App shape:** menu bar icon (status, mount/unmount) + SwiftUI window for connection management.
- **License/distribution:** MIT. **Phase 1 (now): personal-use development builds** signed with a free Apple ID personal team — build from source in Xcode, run locally. **Phase 2 (requires paid Developer ID, deferred):** notarized GitHub releases outside the App Store; Homebrew cask later. No telemetry.

### Explicitly out of v1 (roadmap, not scope)

- S3-compatible, WebDAV, Google Drive/Dropbox backends
- Offline sync / pinned files / conflict resolution
- File Provider "integrated" mode
- Sparkle auto-updates
- macOS < 26 support (an NFS-loopback backend could be added later behind the same core if demand appears)

## 2. Architecture

Four Swift packages shared by two thin executables:

```
┌─ Mimic.app (SwiftUI) ────────────────┐   ┌─ MimicFS.appex (FSKit extension) ─┐
│  MenuBarExtra: status, mount toggles │   │  FSUnaryFileSystem                │
│  Connections window: add/edit servers│   │  translates kernel ops → VFSCore  │
│  MountManager: mounts/unmounts       │   └────────────┬──────────────────────┘
└────────────┬─────────────────────────┘                │
             │      both processes link the same Swift packages
     ┌───────┴────────────────────────────────────────┴────────┐
     │ VFSCore         RemoteFS protocol: list / stat /         │
     │                 read-range / write / mkdir / rename /    │
     │                 delete                                   │
     │ SFTPBackend     implements RemoteFS via Citadel          │
     │                 (SwiftNIO SSH)                           │
     │ CacheLayer      chunked on-disk LRU read cache +         │
     │                 TTL'd metadata cache                     │
     │ ConnectionStore configs in app-group container,          │
     │                 secrets in Keychain shared access group  │
     └───────────────────────────────────────────────────────────┘
```

**Why this shape:** the FSKit extension runs as a separate process managed by `fskitd`, not by the app. All real logic therefore lives in shared packages; app and extension are thin shells. The `RemoteFS` protocol is the extension seam for future backends: S3 support is "implement `RemoteFS`," not a rewrite. Every package is unit-testable without Finder, FSKit, or a network.

### Component responsibilities

| Unit | Does | Depends on |
|---|---|---|
| `VFSCore` | Defines `RemoteFS` protocol, `RemoteFSError`, path/attribute types; composes a backend with the cache | nothing (Foundation only) |
| `SFTPBackend` | SFTP implementation of `RemoteFS`; connection lifecycle, auto-reconnect with backoff, host-key verification | VFSCore, Citadel |
| `CacheLayer` | 2 MB chunk read cache, on-disk LRU (default cap 1 GB, configurable); dir/attr cache with ~5 s TTL; write-through invalidation | VFSCore |
| `ConnectionStore` | CRUD for connection configs (app group); Keychain (shared access group) for passwords/passphrases; SSH keys referenced by file path | Foundation, Security |
| `Mimic.app` | MenuBarExtra UI, connections window, onboarding, `MountManager` | all packages |
| `MimicFS.appex` | `FSUnaryFileSystem` conformance; maps FSKit item ops onto `VFSCore`; maps `RemoteFSError` → POSIX errno | all packages, FSKit |

## 3. Key decisions

| Decision | Choice | Rationale |
|---|---|---|
| SFTP library | **Citadel** (MIT, on Apple's SwiftNIO SSH) | Pure Swift, no C linkage pain, active. Fallback: libssh2 wrapper if Citadel disappoints on performance or protocol coverage. |
| Mounting on macOS 26 | Shell out to `/sbin/mount -F -t mimic ssh://user@host/path` behind a `MountStrategy` protocol | Only option on 26. A second `FSClient.mountSingleVolume` strategy is added when macOS 27 GAs (~Sept 2026) and preferred at runtime. |
| URL scheme | Extension declares `FSSupportedSchemes: [ssh]` (later `s3`, `webdav`) | FSKit's designed mechanism for network filesystems. |
| Config handoff app ↔ extension | App-group container for connection configs; Keychain shared access group for secrets | The extension process must resolve `ssh://…` mount URLs to full connection configs + credentials without the app running. |
| Read cache | Chunked (2 MB), on-disk LRU; short-TTL metadata cache | Finder hammers stat and re-reads; chunking makes previews and video scrubbing fast without whole-file downloads. |
| Writes | Pass-through, then invalidate affected chunks/metadata | No sync engine, no conflicts, cache never serves stale data Mimic itself wrote. |
| Security | Keychain-only secrets; TOFU host-key verification with explicit fingerprint prompt on first connect; no telemetry | Table stakes for an SSH tool from a security-credible author. |
| License | MIT | Maximizes adoption and contribution for an OSS public app. |

## 4. UX flow

1. **First run:** onboarding sheet explains and deep-links the one-time enable step (System Settings → General → Login Items & Extensions → File System Extensions). This is FSKit's roughest edge (including a known Settings bug where the toggle greys out outside "By Category" view) — Mimic out-polishes everyone here with explicit guidance and a "verify it's enabled" check.
2. **Add connection:** window form — host, port (22), username, auth (password / key file + passphrase), remote path, volume name. "Test connection" button; first connect shows host-key fingerprint prompt.
3. **Mount:** click connection in menu bar → volume appears under `/Volumes/<name>` in Finder.
4. **Status:** menu bar icon reflects per-connection state (mounted / connecting / degraded / error); menu shows connections with toggle, recent errors, and cache usage.
5. **Unmount:** from menu bar or Finder eject — both work, always, even if the server is unreachable.

## 5. Error handling

- Typed errors end-to-end: `RemoteFSError` in the core, mapped to POSIX errno at the FSKit boundary (that is what the kernel speaks).
- Every remote call has an aggressive timeout; Finder must never beachball on a dead server.
- Network drop: in-flight ops fail with one retry; `SFTPBackend` reconnects with exponential backoff; menu bar shows degraded state; ops resume transparently on reconnect.
- Unmount with the server gone always succeeds (cached metadata satisfies FSKit teardown).
- User-facing errors are actionable sentences ("Key rejected by server — check the username or key for kyra-nest"), not errno codes.

## 6. Testing

| Layer | Method |
|---|---|
| VFSCore, CacheLayer | Unit tests with in-memory mock `RemoteFS` (chunk eviction, TTL expiry, invalidation-on-write, error mapping) |
| SFTPBackend | Integration tests against a local Docker `sshd` container (auth matrix, reconnect, large files, unicode paths) |
| End-to-end | Scripted Finder checklist against real servers (VPS, kyra-nest via Tailscale): copy in/out, Quick Look, rename, video scrub, server-killed-mid-operation |

## 7. Risks

1. **Pioneer risk** — no OSS FSKit network FS exists to reference; undocumented behavior likely. Mitigation: fuse-t's issue tracker documents most landmines; `VFSCore` is mount-tech-agnostic, so worst case an NFS-loopback backend can be added without touching the core.
2. **Shell-out mount friction on macOS 26** (permissions, sandbox interplay). Known-working per fuse-t/macFUSE usage; macOS 27's `mountSingleVolume` retires it (~2 months to GA).
3. **Cache coherency pre-27:** no kernel-cache invalidation API when the server changes files externally; short metadata TTLs mitigate; adopt the macOS 27 invalidation APIs when GA.
4. **No paid Apple Developer ID yet** — v1 targets personal-use builds signed with a free personal team (works locally; free provisioning profiles expire and need periodic rebuilds). Distributing signed/notarized binaries to other users is blocked until a paid Developer ID exists. Community reports local FSKit dev-signing as finicky; budget debugging time for the first successful mount.
5. **Citadel maturity** for heavy concurrent SFTP I/O is unproven at this scale; the `RemoteFS` seam contains the blast radius if a swap to libssh2 becomes necessary.

## 8. Success criteria for v1

- Mount an SFTP server from the menu bar; browse, Quick Look, copy both directions, rename, delete in Finder — all noticeably snappier than raw SFTP thanks to the cache.
- Survive: network drop mid-transfer, server reboot, Mac sleep/wake — no Finder hangs, clear status, clean recovery.
- A stranger can clone the repo, `xcodebuild`, and mount their own server following the README.
- All unit/integration tests green in CI (GitHub Actions, macOS 26 runner).
