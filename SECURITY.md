# Security

Apple Pi is a terminal cockpit. Its job is to start local Pi processes or SSH-backed Pi processes and keep those terminals organized in a native macOS app.

This page describes what the current codebase does, how to verify release artifacts, and what to report.

## Supported Versions

Public releases are distributed as open-source, ad-hoc signed macOS builds unless the release notes say otherwise.

Ad-hoc signing is not Apple Developer ID notarization. It verifies bundle structure and lets macOS understand the app as a signed bundle, but it does not give the app Apple's Gatekeeper trust stamp. Users should verify the release hash, inspect the source, and build locally if they want the strongest guarantee.

## Trust Boundaries

Apple Pi does not sandbox Pi. Pi sessions run with the same permissions they would have if you launched them yourself from Terminal.

Local mode starts the configured Pi executable on your Mac.

Remote SSH mode starts `/usr/bin/ssh` and asks the remote host to run the configured Pi executable. The app does not store SSH passwords or private keys. Authentication is handled by macOS SSH and your existing SSH configuration.

When notifications are enabled, local mode passes a bundled Pi extension to Pi with `--extension`. That helper listens for Pi notification-related events and writes OSC 777 terminal notification sequences. It is loaded per local session and does not modify the user's Pi agent configuration.

Remote SSH sessions run Pi on the remote host, so the bundled local notification helper is not automatically available there. Remote notification behavior depends on extensions and configuration present on the remote machine.

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

For remote session browsing, the app runs a short `python3 -c ...` script over SSH. That script scans remote session roots and returns session metadata as JSON.

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

The host preference can include the local Pi executable path, agent directory, remote host, remote user, remote port, and remote Pi executable path.

The app does not intentionally store SSH passwords, Pi session contents, API keys, model credentials, or terminal transcript copies.

Notification preferences are stored with the rest of the appearance preferences. The bundled notification helper itself is part of the app bundle, not a file written into the Pi agent directory.

## Network Behavior

The app has two network-related paths in the current codebase.

On launch, the app checks GitHub for a newer release with one anonymous `GET` to:

```text
https://api.github.com/repos/dodo-reach/apple-pi/releases/latest
```

That check is throttled to once every 24 hours and does not send session data, project paths, credentials, or Pi configuration.

Remote mode uses `/usr/bin/ssh`:

- Session browsing uses `ssh -o BatchMode=yes -o ConnectTimeout=8`.
- Interactive remote Pi tabs use `ssh -tt`.

Any network access made by Pi itself is outside Apple Pi and should be evaluated as Pi behavior.

## Release Artifact Verification

Users can verify a release before launching it:

```sh
shasum -a 256 "apple-pi-<version>-<build>.zip"
ditto -x -k "apple-pi-<version>-<build>.zip" /tmp/apple-pi-verify
codesign --verify --deep --strict --verbose=2 "/tmp/apple-pi-verify/Apple Pi.app"
codesign --display --verbose=4 "/tmp/apple-pi-verify/Apple Pi.app"
plutil -p "/tmp/apple-pi-verify/Apple Pi.app/Contents/Info.plist"
```

Optional Gatekeeper check:

```sh
spctl --assess --type execute --verbose=4 "/tmp/apple-pi-verify/Apple Pi.app"
```

For ad-hoc builds, Gatekeeper may reject the app because it is not Developer ID notarized. That is expected. Treat the SHA-256 hash, source code, and local rebuild path as the release trust chain.

More details are in [Verify An Install](docs/VERIFY_INSTALL.md).

## Build Verification

Developers can run:

```sh
swift test
script/package_release.sh
codesign --verify --deep --strict --verbose=2 "dist/Apple Pi.app"
```

The test suite currently covers shell quoting, local and remote launch construction, session-root resolution, invalid settings handling, trust behavior, remote delete safety, remote configuration summaries, and configuration summary counting.
It also covers OSC 777 notification payload parsing and local notification-extension launch gating.

## Reporting Vulnerabilities

If you find a vulnerability, report it privately to the maintainer before opening a public issue.

Please include:

- affected version or commit
- macOS version
- whether the issue is local mode, remote SSH mode, packaging, or documentation
- reproduction steps
- expected behavior
- actual behavior
- any relevant terminal output or crash logs

Do not include secrets, private SSH keys, API keys, or real session transcripts unless they are redacted.

## Security Non-Goals

Apple Pi does not currently provide:

- process sandboxing for Pi
- SSH key generation or storage
- password storage
- malware scanning of session files or project files
- automatic update security
- remote host hardening
- remote session file deletion
- protection from commands typed into the embedded terminal

Treat every Pi session as a terminal session with your user permissions.
