# Security

## Threat Model

Codex Switchboard is a local-only macOS menu bar utility. Its main sensitive asset is the user's Codex/OpenAI auth data stored on disk.

Codex Switchboard assumes:

- The macOS user account is trusted.
- Other local users and processes should not be able to read Codex Switchboard token files.
- Network responses from unofficial ChatGPT/Codex endpoints may fail or change shape.
- Users only add and switch accounts/workspaces they own or are authorized to use.

## Local Storage

Codex Switchboard stores token-containing files under `~/Library/Application Support/CodexSwitchboard/`. Sensitive files are written with `0600` permissions, and token/backups directories are owner-only. The app writes `~/.codex/auth.json` only after an explicit manual switch action.

Codex Switchboard does not intentionally log access tokens, refresh tokens, ID tokens, bearer headers, OAuth response bodies, or full auth JSON.

## Network

Codex Switchboard calls best-effort ChatGPT/Codex web endpoints directly from the local app. It does not sync tokens, share data with a remote service, or run external automation hooks.

The temporary OAuth callback listener binds to localhost during login capture and closes after success, cancellation, timeout, or app termination.

## Reporting

For now, report security issues privately to the repository owner. Do not include live tokens or full auth files in bug reports.
