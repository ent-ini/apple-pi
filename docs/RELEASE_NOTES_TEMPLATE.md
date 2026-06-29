# pi-app <version>

Public release of pi-app, a native macOS app for organising Pi coding-agent sessions.

## Download

- `pi-app-<version>-<build>.zip`
- SHA-256: `<sha256>`

## Requirements

- macOS 14 or newer
- Pi installed locally, **or** a remote host running [pi-appd](https://github.com/ent-ini/apple-pi) and Pi

## Highlights

- Browse Pi session groups and `.jsonl` sessions.
- Resume, fork, and start local Pi sessions.
- Start temporary local sessions with `--no-session`.
- Render open Pi conversations as chat (message bubbles, tool call/result disclosure rows, attachments, voice notes).
- Keep multiple conversations open and switch between them from the sidebar.
- Talk to a remote host running `pi-appd` over bearer-token-authenticated HTTP.
- Browse and start remote sessions without storing Pi session transcripts.
- Tune the app appearance: window/sidebar/chat opacity, accent color, transparent titlebar, dark/light mode.
- Receive macOS notifications from local sessions through the bundled OSC 777 helper.
- Check for newer GitHub releases without automatic downloads or installs.

## Install

Unzip the release, move `pi-app.app` to `/Applications`, and launch it.

macOS may warn that the app cannot be verified because the normal release is ad-hoc signed, not Developer ID notarized. See:

- [Install](INSTALL.md)
- [Verify An Install](VERIFY_INSTALL.md)

## Verification

```sh
shasum -a 256 "pi-app-<version>-<build>.zip"
codesign --verify --deep --strict --verbose=2 "pi-app.app"
codesign --display --verbose=4 "pi-app.app"
plutil -p "pi-app.app/Contents/Info.plist"
```

For ad-hoc builds, Gatekeeper assessment may reject the app. That is expected for this signing model. Use the published SHA-256 hash, source tag, code signature structure, and local rebuild path as the trust chain.

## Notes

- pi-app does not install Pi.
- pi-app does not store model API keys or Pi session transcripts.
- Remote access is handled by the `pi-appd` HTTP daemon.
- Remote API mode can browse, start, and resume remote sessions, but it does not delete remote session files.
- Remote notifications require notification support configured on the remote host; the bundled helper is only loaded into local sessions started by pi-app.
- SwiftTerm is vendored at `Vendor/SwiftTerm` for a future in-app terminal surface. The current release renders Pi conversations as chat, not as a SwiftTerm-backed terminal view.
- The app checks GitHub releases once every 24 hours and never updates itself automatically.

## Links

- [Security](../SECURITY.md)
- [Privacy](../PRIVACY.md)
- [Third-Party Notices](../THIRD_PARTY_NOTICES.md)
