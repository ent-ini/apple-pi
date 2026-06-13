# Release Checklist

Use this checklist for a public Apple Pi release. For the full maintainer workflow, see [Release Process](docs/RELEASE_PROCESS.md).

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
- remote SSH command construction
- session-root resolution
- project trust handling
- invalid settings handling
- remote delete safety
- remote configuration summaries
- configuration summary counts

## Build

For a release package:

```sh
VERSION=<version> BUILD_NUMBER=<build> script/package_release.sh
```

Expected outputs:

```text
dist/Apple Pi.app
dist/apple-pi-<version>-<build>.zip
```

## Bundle Verification

```sh
codesign --verify --deep --strict --verbose=2 "dist/Apple Pi.app"
codesign --display --verbose=4 "dist/Apple Pi.app"
plutil -lint "dist/Apple Pi.app/Contents/Info.plist"
plutil -p "dist/Apple Pi.app/Contents/Info.plist"
otool -L "dist/Apple Pi.app/Contents/MacOS/ApplePi"
```

Confirm:

- ad-hoc signing identity, unless the release notes explicitly say otherwise.
- `CFBundleExecutable` is `ApplePi`.
- `CFBundlePackageType` is `APPL`.
- `LSApplicationCategoryType` is `public.app-category.developer-tools`.
- `LSMinimumSystemVersion` is `14.0`.
- Version and build number match the release notes.
- App icon appears in Finder.

## Gatekeeper Reality Check

This project does not use a paid Apple Developer account for normal releases, so release builds are ad-hoc signed and not Developer ID notarized.

You can still run Gatekeeper assessment:

```sh
spctl --assess --type execute --verbose=4 "dist/Apple Pi.app"
```

For ad-hoc builds, rejection is expected. Do not present Gatekeeper acceptance as the trust proof for this release model. Publish the SHA-256 hash, source tag, and verification instructions instead.

## Manual App Test Pass

- Launch `dist/Apple Pi.app`.
- Confirm the app icon appears in Finder and the Dock.
- Open Settings.
- Verify local Pi executable and agent directory defaults.
- Change appearance settings and confirm they persist after relaunch.
- Refresh sessions.
- Confirm existing local sessions load from the configured session root.
- Open a new local session.
- Resume an existing session.
- Open an ephemeral session.
- Close a terminal tab and confirm the process is terminated.
- Use tab reconnect on an exited session.
- Confirm tab reconnect is unavailable while a session is still running.
- Use search against projects and sessions.
- Collapse and reopen the project and session panes.
- Use the Pi context popover and verify paths are correct.
- Open or reveal Pi settings, instruction, and resource paths when present.
- Quit and relaunch to confirm settings and pane layout persist.

## Remote SSH Test Pass

Complete this section if remote support is included in the release notes.

- Confirm `ssh user@host` works in Terminal.
- Confirm `python3` exists on the remote host.
- Confirm the remote Pi executable works in Terminal.
- Configure Remote SSH mode in app settings.
- Refresh remote sessions.
- Start a new remote session.
- Resume an existing remote session.
- Confirm remote session deletion is not offered in the session context menu.
- Confirm the Pi context popover identifies the context as Remote SSH and does not expose local settings/trust counts for remote paths.
- Test a non-default SSH port if advertised.
- Confirm the app does not require storing an SSH password.

## Release Artifact

Compute the zip hash:

```sh
shasum -a 256 "dist/apple-pi-<version>-<build>.zip"
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
