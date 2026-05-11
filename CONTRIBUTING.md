# Contributing

Thanks for helping improve Codex Switchboard.

Before opening a pull request:

- Keep the app local-first. Do not add remote sync, account sharing, or automation hooks.
- Do not log tokens, bearer headers, OAuth responses, or full auth JSON.
- Keep sensitive files owner-only and preserve the documented storage contract.
- Run `swift test`.
- For UI changes, run `./build-app.sh` and check the generated app locally.

Security reports should follow [SECURITY.md](SECURITY.md).
