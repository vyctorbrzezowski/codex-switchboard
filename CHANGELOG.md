# Changelog

All notable changes to Codex Switchboard will be documented here.

## 1.0.10 - 2026-07-11

- Fixed shared-auth safety checks so the unified `ChatGPT.app` is treated as a running Codex consumer before CLI account switches.
- Made auth-file replacement atomic and owner-only, preserving the existing login if staging or replacement fails.

## 1.0.9 - 2026-07-11

- Added support for the unified `ChatGPT.app` while retaining compatibility with the legacy `Codex.app`.
- Validated the desktop app by bundle identifier so the older native ChatGPT app is not mistaken for Codex Desktop.
- Updated desktop detection, process safety checks, account switching, app relaunching, icon fallback, and CLI discovery for the new app path.
- Added separate Codex Desktop and CLI auth-surface status, local profile switching, and the `codex-switchboard` CLI.
- Added guarded consumer detection and file-backed auth-store checks so switches remain explicit and local-first.
- Added opt-in auto-swap policies for low-quota failover, with paid-only candidate ranking, dry-run support, cooldowns, hourly limits, and redacted local audit history.
- Hardened shared-auth consumer handling, token-rotation identity matching, per-surface credential-store detection, and concurrent audit writes.
- Added an orchestrator skill for inspecting and switching local Codex profiles safely.

## 1.0.8 - 2026-05-29

- Removed every `grant_type=refresh_token` path from Switchboard; the app now never spends refresh tokens.
- Kept only explicit login code exchange (`grant_type=authorization_code`) for adding or re-logging accounts.
- Added a production-source guard test so refresh-token grants cannot be reintroduced silently.
- Added a local read-only auth watcher script for diagnosing Codex auth rotations without logging raw tokens.
- Left token freshness to Codex itself, with Switchboard passively mirroring `~/.codex/auth.json` after Codex rotates it.

## 1.0.7 - 2026-05-29

- Added a Codex auth mirror that keeps captured profiles fresh when `~/.codex/auth.json` changes after Codex or ChatGPT rotates tokens.
- Synced the live Codex auth back into its matching captured profile before switching accounts so rotated refresh tokens are not lost.
- Added just-in-time account switching refresh. Superseded by 1.0.8 because Switchboard should never spend refresh tokens.
- Restarted Codex/app-server after account switches so the running session does not keep an old token in memory.
- Skipped token mirroring when no saved profile matches the live identity or when multiple profiles match ambiguously.

## 1.0.6 - 2026-05-27

- Fixed targeted re-login getting stuck after the ChatGPT consent screen by making the local OAuth callback server read and respond to the browser callback immediately.
- Kept usage refresh out of the login callback path so account capture can finish before balance checks run in the background.

## 1.0.5 - 2026-05-27

- Disabled background OAuth token refresh during usage updates so Codex Switchboard does not rotate refresh tokens while Codex sessions are active.
- Kept expired accounts visible with their re-login state instead of trying to repair them silently.
- Added an OpenAI `login_hint` for targeted re-login flows so the selected account email can be prefilled by the auth page.

## 1.0.4 - 2026-05-22

- Added automatic access-token refresh when a Codex usage request returns `401`.
- Persisted refreshed tokens back to the local account store and captured Codex profiles.
- Retried usage fetches with the refreshed access token before requiring manual re-login.
- Showed `Refresh failed - re-login required` when refresh tokens are missing, reused, rejected, or still produce a rejected access token.
- Distinguished invalidated and revoked tokens from expired tokens so the app does not burn refresh tokens on unrecoverable auth states.

## 1.0.3 - 2026-05-21

- Added collapsible waiting-for-reset sections, including a dedicated collapsed-by-default free-plan group.
- Added clearer free-plan reset timing when session quota is depleted but weekly quota remains.
- Kept the selected compact/expanded information mode across popover opens.
- Improved exhausted-account ordering so paid accounts surface before free-plan reset waiters, then by soonest reset.
- Preserved re-login controls for free-plan waiting rows and added coverage for the new reset-state behavior.

## 1.0.2 - 2026-05-14

- Fixed an account list bug where accounts with failed or unavailable usage responses could disappear from the menu bar list.
- Kept errored accounts visible with their error/re-login state instead of filtering them out of search and list sections.
- Labeled expired/revoked auth errors as `Expired or revoked` and made the `Re-login` action persistent for those accounts.

## 1.0.1 - 2026-05-12

- Improved account capture responsiveness by saving new OAuth accounts from local token identity without making an extra workspace metadata call in the post-login path.
- Debounced the refresh that runs after adding or relogging an account, so repeated account setup does not trigger unnecessary full refreshes between captures.
- Queued one follow-up refresh when a refresh is requested while another refresh is still running, avoiding stale state without blocking the UI.
- Reduced auxiliary metadata request timeouts so workspace/account details cannot hold up the main usage refresh for too long.
- Added a 15-second OAuth token exchange timeout.
- Hardened the localhost OAuth callback listener by waiting for ready connections before reading requests and force-closing callback responses.
- Removed the local mock account mode and seed script from the release build path.
- Refined the menubar UI with a clearer expand/compact toggle and a contextual `Use in Codex` account action.
