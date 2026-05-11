# Codex Switchboard

Codex Switchboard is a local-first macOS menu bar app for people who use Codex with multiple accounts or workspaces they control. It shows best-effort Codex/OpenAI usage, groups accounts by workspace, marks invalid or deactivated accounts, shows which account is active in Codex, and lets you manually switch the active local Codex account.

Codex Switchboard is not affiliated with OpenAI. It does not change Codex/OpenAI limits, share accounts, or automate account cycling. It only helps you see local usage state and manually switch between accounts/workspaces you control.

## Requirements

- macOS 13 or newer
- Xcode Command Line Tools or Xcode with Swift 5.9 or newer
- Codex.app installed in `/Applications/Codex.app` for account switching

## Install From Source

This first public release is source-first and intended for developers. It does not ship a signed and notarized public binary yet.

```bash
git clone https://github.com/vyctorbrzezowski/codex-switchboard.git
cd codex-switchboard
swift test
swift build
./build-app.sh
open dist/CodexSwitchboard.app
```

`build-app.sh` creates a local ad-hoc-signed app bundle. Public binary distribution should use Developer ID signing and notarization.

## Data Access

Codex Switchboard reads and writes only local files:

- Reads and writes `~/Library/Application Support/CodexSwitchboard/`
- Reads `~/.codex/auth.json` to detect the active Codex account
- Writes `~/.codex/auth.json` only when you manually choose an account in the menu bar

On a fresh install, Codex Switchboard starts with no accounts. Add each account from the menu bar login flow.

Account switching appears only when Codex.app is installed locally. Without Codex.app, Codex Switchboard works as a usage monitor for added accounts.

Sensitive app-owned files are written with `0600` permissions. Token-containing directories and backups are kept under `~/Library/Application Support/CodexSwitchboard/` with owner-only directory permissions.

## Stored Files

- `~/Library/Application Support/CodexSwitchboard/accounts.json`
- `~/Library/Application Support/CodexSwitchboard/profiles/<profile>/auth.json`
- `~/Library/Application Support/CodexSwitchboard/profiles/<profile>/meta.json`
- `~/Library/Application Support/CodexSwitchboard/accounts-snapshot.json`
- `~/Library/Application Support/CodexSwitchboard/team-name-cache.json`
- `~/Library/Application Support/CodexSwitchboard/backups/<timestamp>-remove-account/`

Removal actions create a backup before deleting app-owned profile data.

## Network Calls

Codex Switchboard uses local Codex/OpenAI auth tokens to make best-effort requests to ChatGPT/Codex web endpoints:

- `https://chatgpt.com/backend-api/codex/usage`
- `https://chatgpt.com/backend-api/accounts/check/v4-2023-04-27`
- `https://auth.openai.com/oauth/authorize`
- `https://auth.openai.com/oauth/token`

These endpoints are not an official public API contract for this app. Behavior may change or fail without notice.

## Security Posture

Codex Switchboard does not sync tokens, expose a remote service, or log bearer tokens. The OAuth callback server binds only to `localhost:1455` during login capture and closes after the flow finishes or times out.

See [SECURITY.md](SECURITY.md) for the short threat model.

## Contributing

Issues and pull requests are welcome. Keep changes local-first, avoid token logging, and run `swift test` before opening a PR.
