# Changelog

All notable changes to Codex Switchboard will be documented here.

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
