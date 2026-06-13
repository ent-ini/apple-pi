# Apple Pi <version>

First public release of Apple Pi, a native macOS app for organizing Pi terminal sessions.

## Download

- `apple-pi-<version>-<build>.zip`
- SHA-256: `<sha256>`

## Requirements

- macOS 14 or newer
- Pi installed locally, or SSH access to a remote host that can run Pi
- `python3` on the remote host for remote session browsing

## Highlights

- Browse Pi session groups and `.jsonl` sessions.
- Resume, fork, and start local Pi sessions.
- Start temporary local sessions with `--no-session`.
- Open multiple terminal tabs backed by SwiftTerm.
- Connect to remote hosts through the system SSH client.
- Browse and start remote SSH sessions without storing SSH passwords or keys.
- Tune the app appearance, terminal theme, font, opacity, panes, and accent color.
- Receive macOS notifications from local sessions through the bundled OSC 777 helper.
- Check for newer GitHub releases without automatic downloads or installs.

## Install

Unzip the release, move `Apple Pi.app` to `/Applications`, and launch it.

macOS may warn that the app cannot be verified because the normal release is ad-hoc signed, not Developer ID notarized. See:

- [Install](INSTALL.md)
- [Verify An Install](VERIFY_INSTALL.md)

## Verification

```sh
shasum -a 256 "apple-pi-<version>-<build>.zip"
codesign --verify --deep --strict --verbose=2 "Apple Pi.app"
codesign --display --verbose=4 "Apple Pi.app"
plutil -p "Apple Pi.app/Contents/Info.plist"
```

For ad-hoc builds, Gatekeeper assessment may reject the app. That is expected for this signing model. Use the published SHA-256 hash, source tag, code signature structure, and local rebuild path as the trust chain.

## Notes

- Apple Pi does not install Pi.
- Apple Pi does not manage SSH keys or store SSH passwords.
- Apple Pi does not store model API keys or Pi session transcripts.
- Remote SSH mode can browse, start, and resume remote sessions, but it does not delete remote session files.
- Remote notifications require notification support configured on the remote host; the bundled helper is only loaded into local sessions started by Apple Pi.
- The app checks GitHub releases once every 24 hours and never updates itself automatically.

## Links

- [Security](../SECURITY.md)
- [Privacy](../PRIVACY.md)
- [Third-Party Notices](../THIRD_PARTY_NOTICES.md)
