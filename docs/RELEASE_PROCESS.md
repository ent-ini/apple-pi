# Release Process

This process is for maintainers preparing a public Apple Pi release.

## 1. Confirm Release Metadata

Choose:

- version
- build number
- bundle identifier
- release notes
- signing model
- published SHA-256 hash

The packaging script defaults are:

```text
APP_NAME="Apple Pi"
ARCHIVE_NAME=apple-pi
PRODUCT_NAME=ApplePi
BUNDLE_IDENTIFIER=com.dodoreach.ApplePi
VERSION=0.1.0
SIGN_IDENTITY=-
```

Normal releases use the default ad-hoc signing identity (`SIGN_IDENTITY=-`). This is not Apple Developer ID notarization.

## 2. Verify Source

```sh
git status --short
swift test
```

Review changes to:

- `Package.swift`
- `Sources/ApplePi`
- `Tests/ApplePiTests`
- `script/package_release.sh` and `script/Info.plist.tpl`
- `Vendor/SwiftTerm`
- release docs

### Bundle metadata source of truth

`script/package_release.sh` is the single source of truth for the bundle
metadata written into `dist/Apple Pi.app/Contents/Info.plist`. The actual
plist payload is kept at `script/Info.plist.tpl` so the file is diffable
and reviewable in PRs; `package_release.sh` substitutes the
`APP_NAME`, `BUNDLE_IDENTIFIER`, `VERSION`, `BUILD_NUMBER`, and
`EXECUTABLE_NAME` placeholders at build time and validates the result
with `plutil -lint` before signing. If you need to add a new
`Info.plist` key, edit `script/Info.plist.tpl` — do not duplicate the
plist body into another file.

## 3. Build A Release Candidate

```sh
VERSION=<version> \
BUILD_NUMBER=<build> \
script/package_release.sh
```

Expected outputs:

```text
dist/Apple Pi.app
dist/apple-pi-<version>-<build>.zip
```

## 4. Verify The Bundle

```sh
codesign --verify --deep --strict --verbose=2 "dist/Apple Pi.app"
codesign --display --verbose=4 "dist/Apple Pi.app"
plutil -lint "dist/Apple Pi.app/Contents/Info.plist"
plutil -p "dist/Apple Pi.app/Contents/Info.plist"
```

Confirm:

- bundle identifier
- version
- build number
- ad-hoc signature, unless the release notes explicitly say otherwise
- minimum macOS version
- app icon

## 5. Gatekeeper Reality Check

Normal releases are ad-hoc signed and not Developer ID notarized.

You can run:

```sh
spctl --assess --type execute --verbose=4 "dist/Apple Pi.app"
```

For ad-hoc builds, Gatekeeper may reject the app. That is expected. The release should be trusted through the source tag, SHA-256 hash, code signature structure, and reproducible local build path.

## 6. Compute Release Hash

```sh
shasum -a 256 "dist/apple-pi-<version>-<build>.zip"
```

Publish the SHA-256 hash next to the release artifact.

## 7. Manual Test Pass

Run the manual checklist in [Release Checklist](../RELEASE_CHECKLIST.md).

At minimum, test:

- launch from Finder
- Settings
- local session refresh
- new local session
- resume existing session
- ephemeral session
- tab close and reconnect
- reconnect unavailable while a tab is still running
- remote API mode, if advertised in the release notes
- `Test Remote API` returns a project/session count, not a connection error
- `Copy curl` produces a working `curl -H 'Authorization: Bearer …'` line
- remote delete action absent for remote sessions
- quit and relaunch preference persistence

## 8. Publish

Create and push a matching git tag, attach the ad-hoc signed zip, include the SHA-256 hash, and link to:

- [Install](INSTALL.md)
- [Verify An Install](VERIFY_INSTALL.md)
- [Security](../SECURITY.md)
- [Privacy](../PRIVACY.md)

Use [Release Notes Template](RELEASE_NOTES_TEMPLATE.md) as the starting point for the GitHub release body.
