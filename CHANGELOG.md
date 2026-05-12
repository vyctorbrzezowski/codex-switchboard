# Changelog

All notable changes to Codex Switchboard will be documented here.

## 1.0.1 - 2026-05-12

- Improved account capture responsiveness by saving new OAuth accounts from local token identity without making an extra workspace metadata call in the post-login path.
- Debounced the refresh that runs after adding or relogging an account, so repeated account setup does not trigger unnecessary full refreshes between captures.
- Queued one follow-up refresh when a refresh is requested while another refresh is still running, avoiding stale state without blocking the UI.
- Reduced auxiliary metadata request timeouts so workspace/account details cannot hold up the main usage refresh for too long.
- Added a 15-second OAuth token exchange timeout.
- Hardened the localhost OAuth callback listener by waiting for ready connections before reading requests and force-closing callback responses.
- Removed the local mock account mode and seed script from the release build path.
- Refined the menubar UI with a clearer expand/compact toggle and a contextual `Use in Codex` account action.
