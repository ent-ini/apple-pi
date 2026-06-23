# Verify An Install

These checks let users inspect an Apple Pi release before launching it.

Replace `<version>` and `<build>` with the release values.

## 1. Verify The Download Hash

Compare this output with the SHA-256 hash published by the release maintainer:

```sh
shasum -a 256 "apple-pi-<version>-<build>.zip"
```

## 2. Unzip To A Temporary Folder

```sh
rm -rf /tmp/apple-pi-verify
ditto -x -k "apple-pi-<version>-<build>.zip" /tmp/apple-pi-verify
```

## 3. Verify Code Signature

```sh
codesign --verify --deep --strict --verbose=2 "/tmp/apple-pi-verify/Apple Pi.app"
codesign --display --verbose=4 "/tmp/apple-pi-verify/Apple Pi.app"
```

For the normal open-source release, the displayed authority is ad-hoc. That is expected.

Ad-hoc signing can verify structurally with `codesign`, but it is not Apple Developer ID notarization. The hash, source, and reproducible local build path are the important checks.

## 4. Verify Gatekeeper Assessment

```sh
spctl --assess --type execute --verbose=4 "/tmp/apple-pi-verify/Apple Pi.app"
```

An ad-hoc release may be rejected by Gatekeeper because it is not Developer ID notarized. That is expected. If the project later ships a Developer ID notarized build, the release notes should say so explicitly.

macOS may show wording such as Apple cannot check the app for malicious software or the developer cannot be verified. That is a notarization/developer-identity warning, not proof that Apple found malware in the app. If you choose to override it, Apple's documented path is System Settings -> Privacy & Security -> Security -> Open Anyway after first trying to launch the app.

## 5. Inspect Bundle Metadata

```sh
plutil -p "/tmp/apple-pi-verify/Apple Pi.app/Contents/Info.plist"
```

Expected public metadata includes:

- `CFBundleExecutable`: `ApplePi`
- `CFBundlePackageType`: `APPL`
- `LSApplicationCategoryType`: `public.app-category.developer-tools`
- `LSMinimumSystemVersion`: `14.0`

The bundle identifier and version should match the release notes.

Expected app resources include:

- `AppIcon.icns`
- `ApplePiNotifyExtension.mjs`

## 6. Inspect Linked System Libraries

```sh
otool -L "/tmp/apple-pi-verify/Apple Pi.app/Contents/MacOS/ApplePi"
```

This shows the dynamic libraries loaded by the app executable.

## 7. Inspect The Source Build Recipe

The release app is built by:

```sh
script/package_release.sh
```

That script builds the Swift package, creates the `.app` bundle, renders `Info.plist` from `script/Info.plist.tpl`, signs the bundle, verifies the signature, and creates the zip. `script/Info.plist.tpl` is the single source of truth for the bundle metadata (bundle identifier, version, build number, display name, ATS exceptions, etc.); review it alongside any release-tag diff.

The Swift package has one local package dependency:

```text
Vendor/SwiftTerm
```

SwiftTerm is vendored for a future in-app terminal surface; the current release does not link against it. No remote Swift package dependency is declared in `Package.swift`.
