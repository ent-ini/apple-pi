# Release Checklist

Use this checklist for a public pi-app release. For the full maintainer workflow, see [Release Process](docs/RELEASE_PROCESS.md).

## Source Readiness

- Confirm the public version number.
- Confirm the public bundle identifier.
- Confirm the app display name and release artifact names.
- Confirm the release notes.
- Confirm [LICENSE.md](LICENSE.md) is the intended MIT public license.
- Review [Security](SECURITY.md), [Privacy](PRIVACY.md), and [Third-Party Notices](THIRD_PARTY_NOTICES.md).
- Confirm `Vendor/SwiftTerm/LICENSE` is present.
- Run `git status --short` and account for every changed file.

## Automated Verification

```sh
swift test
```

Expected coverage areas:

- shell quoting
- local Pi command construction
- remote API URL/host parsing
- session-root resolution
- project trust handling
- invalid settings handling
- remote delete safety
- remote configuration summaries
- configuration summary counts
- `RemoteSSHSupport` environment-variable allowlist (shared by local and remote)

## Build

For a release package:

```sh
VERSION=<version> BUILD_NUMBER=<build> script/package_release.sh
```

Expected outputs:

```text
dist/pi-app.app
dist/pi-app-<version>-<build>.zip
```

## Bundle Verification

```sh
codesign --verify --deep --strict --verbose=2 "dist/pi-app.app"
codesign --display --verbose=4 "dist/pi-app.app"
plutil -lint "dist/pi-app.app/Contents/Info.plist"
plutil -p "dist/pi-app.app/Contents/Info.plist"
otool -L "dist/pi-app.app/Contents/MacOS/pi-app"
```

Confirm:

- ad-hoc signing identity, unless the release notes explicitly say otherwise.
- `CFBundleExecutable` is `pi-app`.
- `CFBundlePackageType` is `APPL`.
- `LSApplicationCategoryType` is `public.app-category.developer-tools`.
- `LSMinimumSystemVersion` is `14.0`.
- Version and build number match the release notes.
- App icon appears in Finder.

## Gatekeeper Reality Check

This project does not use a paid Apple Developer account for normal releases, so release builds are ad-hoc signed and not Developer ID notarized.

You can still run Gatekeeper assessment:

```sh
spctl --assess --type execute --verbose=4 "dist/pi-app.app"
```

For ad-hoc builds, rejection is expected. Do not present Gatekeeper acceptance as the trust proof for this release model. Publish the SHA-256 hash, source tag, and verification instructions instead.

## Manual App Test Pass

- Launch `dist/pi-app.app`.
- Confirm the app icon appears in Finder and the Dock.
- Open Settings.
- Verify local Pi executable and agent directory defaults.
- Change appearance settings and confirm they persist after relaunch.
- Refresh sessions.
- Confirm existing local sessions load from the configured session root.
- Open a new local session.
- Resume an existing session.
- Open an ephemeral session.
- Close an open chat and confirm the local `pi` process is terminated (or, for remote sessions, the in-flight HTTP stream is cancelled).
- Use the reconnect action on an exited session and confirm it rehydrates the chat from disk.
- Confirm the reconnect action is unavailable while a session is still running.
- Use search against projects and sessions.
- Collapse and reopen the project and session panes.
- Use the Pi context popover and verify paths are correct.
- Open or reveal Pi settings, instruction, and resource paths when present.
- Quit and relaunch to confirm settings and pane layout persist.

## Remote API Test Pass

Complete this section if remote support is included in the release notes.
pi-app talks to the remote host through [pi-appd](https://github.com/ent-ini/apple-pi),
a separate HTTP daemon, not through a built-in SSH client.

- Confirm `pi-appd` is installed on the remote host and reachable at the
  configured URL (for example `http://<host>:<port>/healthz`).
- Confirm the remote Pi executable works on the host that runs `pi-appd`
  (the daemon delegates to it).
- Configure Remote API mode in app settings: `pi-appd URL` and a bearer
  token.
- `Test Remote API` returns a project/session count, not a connection
  or auth error.
- `Copy curl` produces a `curl -H "Authorization: Bearer …"` line that
  works when pasted into Terminal.
- Refresh remote sessions.
- Start a new remote session.
- Resume an existing remote session.
- Confirm remote session deletion is not offered in the session
  context menu.
- Confirm the Pi context popover identifies the context as Remote API
  and does not expose local settings/trust counts for remote paths.
- Confirm the app does not require storing a password, key, or `python3`
  on the remote host.

## Release Artifact

Compute the zip hash:

```sh
shasum -a 256 "dist/pi-app-<version>-<build>.zip"
```

Publish:

- ad-hoc signed zip
- SHA-256 hash
- release notes
- minimum macOS version
- verification instructions from [Verify An Install](docs/VERIFY_INSTALL.md)
- security and privacy links

## GitHub Release

- Create and push a matching git tag.
- Attach the release artifact.
- Include the SHA-256 hash.
- Link to install, verification, security, and privacy docs.
