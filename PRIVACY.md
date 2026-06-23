# Privacy

Apple Pi is a local native macOS app for organising Pi coding-agent sessions as a chat. The current release does not include a built-in SSH client; remote sessions go through a separate [pi-appd](https://github.com/ent-ini/apple-pi) HTTP daemon that you run next to Pi on the remote host.

## Data Collection

The current codebase does not include analytics, telemetry, crash reporting, advertising SDKs, or a custom network service.

## Data The App Reads

Depending on your settings and selected sessions, the app can read:

- Pi agent settings under the configured agent directory
- Pi trust metadata
- Pi session `.jsonl` files
- project-local Pi settings under `<project>/.pi/settings.json`
- project instruction files such as `AGENTS.md`
- resource folders such as `skills`, `prompts`, `themes`, `packages`, and `extensions`

For session list display, the app parses session metadata and message counts from local `.jsonl` files (or, in remote mode, from the JSON that `pi-appd` returns from `/sessions`). Pi remains responsible for the actual session contents and model interactions.

## Data The App Stores

The app stores preferences in macOS `UserDefaults`, including:

- local Pi executable
- agent directory
- `pi-appd` URL
- appearance settings
- pane visibility and pane widths

The host model still carries SSH-shaped fields (remote host, user, port, identity file, `~/.ssh/config` alias) for backwards compatibility with saved configs from earlier previews. The current release does not read them back into a runtime path.

The app does not intentionally store SSH passwords, API keys, model credentials, full chat transcripts, or copies of Pi session files.

The `pi-appd` bearer token and the optional Groq API key (used only for Whisper transcription of voice notes) are stored as `0600` files under Application Support — never in the Keychain. They are scoped per daemon endpoint / per app instance.

## Notifications

If notifications are enabled, local Pi sessions started from Apple Pi are launched with a bundled Pi notification helper. The helper listens for Pi turn-completion events and writes a terminal notification escape sequence back to the app. The app then asks macOS to show the notification.

The helper is loaded for that session only. It is not installed into Pi, and the app does not modify `~/.pi/agent/settings.json` or other Pi package configuration to enable it.

Notification titles and messages are sent to macOS Notification Center for display. Current notification content is limited to app-generated status text such as Pi being ready for input or permission being required.

## Remote Mode

Remote mode is the "Remote API" host in the Settings window. The macOS client sends bearer-token-authenticated HTTP requests to the configured `pi-appd` URL. Authentication, host verification, and network routing are `pi-appd`'s responsibility; the macOS side only stores the bearer token you paste in.

Apple Pi does not shell out to `ssh`, `python3`, or any other tool on the remote host. If you point it at a `pi-appd` you control, that is the only thing the app talks to remotely.

## Pi Behavior

Pi may read project files, send data to model providers, or use network access according to Pi's own configuration and the commands you run. That is outside Apple Pi's code path.

Review your Pi configuration and project trust settings before launching sessions.

## Update Check

On launch, the app performs a single anonymous HTTP GET to:

```
https://api.github.com/repos/ent-ini/apple-pi/releases/latest
```

The only data sent is the request URL plus three headers: `Accept: application/vnd.github+json`, `X-GitHub-Api-Version: 2022-11-28`, and `User-Agent: ApplePi`. The app does not send an authentication token, a device identifier, analytics, telemetry, or any user content, session data, or Pi configuration.

The check is throttled to once every 24 hours, stored as a timestamp in `UserDefaults`. If a newer release exists, the app shows a small in-app pill that links to the GitHub release page in your default browser. The app does not download, install, or replace itself. You stay in control of when and how to update.
