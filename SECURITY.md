# Security

pi-app is a native macOS chat-style session UI for Pi. Local mode starts the configured Pi executable on your Mac; remote mode talks to a separate [pi-appd](https://github.com/ent-ini/apple-pi) HTTP daemon that lives next to Pi on the remote host. There is no built-in SSH client in the current codebase.

This page describes what the current codebase does, how to verify release artifacts, and what to report.

## Supported Versions

Public releases are distributed as open-source, ad-hoc signed macOS builds unless the release notes say otherwise.

Ad-hoc signing is not Apple Developer ID notarization. It verifies bundle structure and lets macOS understand the app as a signed bundle, but it does not give the app Apple's Gatekeeper trust stamp. Users should verify the release hash, inspect the source, and build locally if they want the strongest guarantee.

## Trust Boundaries

pi-app does not sandbox Pi. Pi sessions run with the same permissions they would have if you launched them yourself from Terminal.

Local mode starts the configured Pi executable on your Mac and exchanges RPC traffic with it over stdin/stdout. The remote transport is never involved on the local path.

Remote mode (titled "Remote API" in the UI) talks to `pi-appd` over bearer-token-authenticated HTTP. The Mac client never spawns `ssh`, `python3`, or any other tool on the remote host. Authentication, TLS, and host-key handling are `pi-appd`'s responsibility; the Mac side only stores a per-endpoint bearer token.

The current codebase ships a small `pi-app-askpass` helper binary, an `SSHConfigParser`, an `SSHKeyStore`, and SSH host fields (hostname, port, user, identity file, `~/.ssh/config` alias) on the host model. These were used by an earlier SSH-based remote runtime and are no longer reached from the production code paths. They are kept in the source so a future local-SSH passthrough can reuse them without re-deriving the password/identity plumbing. They are **not** exercised by the current release; in particular, no release of this code calls `ssh` for remote session browsing, turn streaming, or directory listing. Do not rely on them for security boundaries until they are wired up.

When notifications are enabled, local mode passes a bundled Pi extension to Pi with `--extension`. That helper listens for Pi notification-related events and writes OSC 777 terminal notification sequences. It is loaded per local session and does not modify the user's Pi agent configuration.

Remote API sessions run Pi on the remote host (via `pi-appd`), so the bundled local notification helper is not automatically available there. Remote notification behavior depends on extensions and configuration present on the remote machine.

## What The App Reads

The app reads local files from the configured Pi agent directory. The default is:

```sh
~/.pi/agent
```

It can read:

- `settings.json`
- `trust.json`
- session `.jsonl` files under resolved session roots
- instruction files named `AGENTS.md`, `CLAUDE.md`, `SYSTEM.md`, or `APPEND_SYSTEM.md`
- resource directories named `packages`, `extensions`, `skills`, `prompts`, or `themes`

For remote session browsing the app does not run anything on the remote host. It sends HTTPS (or HTTP, if you opt in to the bundled ATS exception for `localhost`/`100.100.11.4`/etc.) to `pi-appd`, which performs the scan on the host it runs on and returns JSON.

## What The App Stores

The app stores host and appearance preferences in macOS `UserDefaults` under keys including:

```text
ApplePi.host
ApplePi.appearance
ApplePi.showsProjectSidebar
ApplePi.showsSessionList
ApplePi.projectSidebarWidth
ApplePi.sessionListWidth
```

The host preference can include the local Pi executable path, the agent directory, the `pi-appd` URL, and the saved bearer-token key. The SSH-related fields (remote host, user, port, identity file, config alias) are also persisted when set, but the current release does not read them back into a runtime path.

The app does not intentionally store SSH passwords, `pi-appd` session contents, API keys, model credentials, or Pi session transcripts.

The bearer token and the Groq API key (used only for optional Whisper transcription) are each stored as a single `0600` file under Application Support — never in the Keychain. They are scoped per daemon endpoint / per app instance and are written with an atomic secure-file helper that fixes the mode from the first byte.

Notification preferences are stored with the rest of the appearance preferences. The bundled notification helper itself is part of the app bundle, not a file written into the Pi agent directory.

## Network Behavior

The app has two network-related paths in the current codebase.

On launch, the app checks GitHub for a newer release with one anonymous `GET` to:

```text
https://api.github.com/repos/ent-ini/apple-pi/releases/latest
```

That check is throttled to once every 24 hours and does not send session data, project paths, credentials, or Pi configuration.

Remote mode talks to the configured `pi-appd` URL with bearer-token HTTP requests:

- `GET /healthz` and `GET /sessions` are used to verify the daemon is reachable (`Test Remote API` in Settings).
- `GET /sessions/stream` is a long-lived SSE feed of catalog snapshots; it auto-reconnects on transient failure.
- `POST /sessions/...` and friends are used for browsing, starting, resuming, and turn streaming.

The macOS app's `Info.plist` opens `NSAllowsArbitraryLoads` and `NSAllowsLocalNetworking` so a local `pi-appd` (and a few hard-coded Tailscale IPs the developer uses) can answer over plain HTTP during development. See `script/Info.plist.tpl` for the exact list.

Any network access made by Pi itself (including outbound calls made on your behalf by the agent) is outside pi-app and should be evaluated as Pi behavior.

## Release Artifact Verification

Users can verify a release before launching it:

```sh
shasum -a 256 "pi-app-<version>-<build>.zip"
ditto -x -k "pi-app-<version>-<build>.zip" /tmp/pi-app-verify
codesign --verify --deep --strict --verbose=2 "/tmp/pi-app-verify/pi-app.app"
codesign --display --verbose=4 "/tmp/pi-app-verify/pi-app.app"
plutil -p "/tmp/pi-app-verify/pi-app.app/Contents/Info.plist"
```

Optional Gatekeeper check:

```sh
spctl --assess --type execute --verbose=4 "/tmp/pi-app-verify/pi-app.app"
```

For ad-hoc builds, Gatekeeper may reject the app because it is not Developer ID notarized. That is expected. Treat the SHA-256 hash, source code, and local rebuild path as the release trust chain.

More details are in [Verify An Install](docs/VERIFY_INSTALL.md).

## Build Verification

Developers can run:

```sh
swift test
script/package_release.sh
codesign --verify --deep --strict --verbose=2 "dist/pi-app.app"
```

The test suite currently covers shell quoting, local Pi command construction, the `RemoteSSHSupport` environment-variable allowlist that is shared by local and remote turn runners, session-root resolution, invalid settings handling, trust behavior, remote delete safety, remote configuration summaries, configuration summary counting, the secure 0600 secret-file writer, the turn-lifecycle / SSE-stream cancellation plumbing, the multipart filename whitelist used by `RemoteDaemonClient` and `GroqTranscriptionClient`, the redaction of bearer tokens in the Remote API section of `SettingsView`, and the non-crashing URL initialisation of the `UpdateCheckService` and Groq endpoints.
It also covers OSC 777 notification payload parsing and local notification-extension launch gating.

## Reporting Vulnerabilities

If you find a vulnerability, report it privately to the maintainer before opening a public issue.

Please include:

- affected version or commit
- macOS version
- whether the issue is local mode, remote API mode, packaging, or documentation
- reproduction steps
- expected behavior
- actual behavior
- any relevant logs or crash dumps

Do not include secrets, private API keys, `pi-appd` bearer tokens, or real session transcripts unless they are redacted.

## Security Non-Goals

pi-app does not currently provide:

- process sandboxing for Pi
- a built-in SSH client (remote mode is `pi-appd` over HTTP, by design)
- SSH key generation or storage
- password storage
- bearer-token rotation or expiry enforcement (the token is whatever you paste in)
- malware scanning of session files or project files
- automatic update security
- remote host hardening
- remote session file deletion
- a SwiftTerm-backed terminal surface (SwiftTerm is vendored but not linked in this release)

Treat every Pi session as a session running with your user permissions.
