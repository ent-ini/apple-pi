# Install

Apple Pi is distributed as an open-source, ad-hoc signed macOS app unless the release notes say otherwise.

Ad-hoc signing is not Apple Developer ID notarization. macOS may say Apple cannot check the app for malicious software, or that the developer cannot be verified. That does not mean Apple found malware in the app; it means the app has not been checked through Apple's paid Developer ID notarization path.

Verify the release hash and source before running it.

## Requirements

- macOS 14 or newer.
- Pi installed locally, **or** a remote host running [pi-appd](https://github.com/ent-ini/apple-pi) and Pi.

Apple Pi does not need `python3` (or any other tool) on the remote host beyond whatever `pi-appd` itself requires. The macOS client talks to the daemon over bearer-token-authenticated HTTP.

## Install From A Release Zip

1. Download the release zip.
2. Verify the zip hash published with the release.
3. Unzip the app.
4. Move `Apple Pi.app` to `/Applications`.
5. Launch the app.
6. If macOS blocks the launch, open System Settings -> Privacy & Security, scroll to Security, then choose Open Anyway.

Command-line example:

```sh
shasum -a 256 "apple-pi-<version>-<build>.zip"
ditto -x -k "apple-pi-<version>-<build>.zip" /tmp/apple-pi-install
mv "/tmp/apple-pi-install/Apple Pi.app" /Applications/
```

Apple documents the override flow in [Open a Mac app from an unknown developer](https://support.apple.com/guide/mac-help/open-a-mac-app-from-an-unknown-developer-mh40616/mac): after a blocked launch attempt, the Open Anyway button is available for about an hour.

## First Configuration

Open Settings and choose a host mode.

For local mode:

- `Local Pi executable`: defaults to `pi`.
- `Agent directory`: defaults to `~/.pi/agent`.

For Remote API mode:

- `pi-appd URL or IP`: the URL or `host:port` of the remote `pi-appd` daemon (for example `http://100.100.20.10:8787`).
- `Bearer token`: paste the daemon's bearer token. It is stored locally as a `0600` file in Application Support — never in the Keychain.
- Use `Test Remote API` before pressing Apply to confirm the URL and token work, and `Copy curl` if you want a one-shot way to check the daemon from a terminal.

The bundled SSH password, identity-file, and `~/.ssh/config` alias fields from earlier previews are no longer required: Remote API mode uses HTTP only, and the SSH plumbing is reserved for a future local SSH passthrough. The fields are kept in the host model so the data shape does not break for anyone who already has a saved config.

The app does not install Pi and does not configure SSH keys. Confirm those work in Terminal first.

## Notifications

For local sessions, Apple Pi includes its own small Pi notification helper inside the app bundle. When notifications are enabled in the app settings, new local sessions are launched with that bundled helper. The app does not install packages into Pi and does not modify `~/.pi/agent/settings.json`.

If notifications are disabled in the app settings, new local sessions are launched without the helper.

For Remote API sessions, Pi runs on the remote host. The bundled local helper is not available there, so notification support requires a Pi notification extension on the remote host.

Remote API mode can browse, start, and resume sessions on the remote host. Apple Pi does not delete remote session files, and local Finder/file actions are disabled or limited for remote paths.

## Useful Terminal Checks

Local Pi:

```sh
which pi
pi --help
```

Remote `pi-appd` reachability (replace the URL and token with the ones configured in Settings):

```sh
curl -H "Authorization: Bearer <token>" http://<host:port>/healthz
```

The Settings pane's `Copy curl` button produces the same command with the values it has on screen.

## Local Test Builds

Developers can build a local test app:

```sh
script/package_release.sh
```

This creates:

```text
dist/Apple Pi.app
```

By default, the package uses an ad-hoc hardened-runtime signature. Public releases use the same transparent signing model unless the release notes say otherwise.
