---
name: codex-switchboard
description: Use when an agent orchestrator needs to inspect Codex Desktop or Codex CLI auth capacity, choose a usable paid Codex profile, or perform an explicit local Codex Switchboard profile switch.
---

# Codex Switchboard

## Overview

Use the local `codex-switchboard` CLI to inspect Codex Desktop/CLI auth surfaces and switch profiles only when the caller explicitly asks for a switch. Use `autoswap run-once` when the caller has enabled policy-driven failover. Treat all auth files as sensitive; never print tokens or raw `auth.json` contents.

## Required Rules

- Use only local CLI commands; do not read or print raw `~/.codex/auth.json` or captured profile auth files.
- Prefer paid usable accounts: `is_free_plan == false`, `usable_for_codex == true`, and `needs_relogin == false`.
- Do not switch to free-plan accounts unless the user explicitly requests that exact profile.
- Do not use `--stop-consumers` unless the user explicitly authorized stopping running Codex Desktop/CLI consumers.
- Prefer `autoswap run-once --dry-run` before a policy-driven switch so the decision and candidate are visible without mutating auth.
- After any switch, verify the selected surface reports the requested `active_profile_key`.
- Report counts, chosen rationale, and safe commands. Avoid pasting full account JSON into chat or logs.

## Workflow

1. Confirm the CLI exists:

```bash
command -v codex-switchboard
```

2. Inspect surfaces and consumer state:

```bash
codex-switchboard doctor --json \
  | jq '{consumers_running, consumer_count, unsupported_surfaces, surfaces: [.surfaces[] | {kind, detected, running, auth_store_mode, supports_file_switching, shared_auth_store}]}'
```

3. Find paid usable profiles:

```bash
codex-switchboard status --json --surface all --paid-only --usable-only \
  | jq '{generated_at, surfaces: [.surfaces[] | {kind, detected, running, active_profile_key, auth_store_mode, shared_auth_store}], accounts: [.accounts[] | {profile_key, plan, usable_for_codex, needs_relogin, session_free_percent, weekly_free_percent, score}]}'
```

4. Choose the highest `score` account that is not free, is usable, and does not need relogin. If no such account exists, stop and report that no paid usable profile is available.

5. Switch only with an explicit local command:

```bash
codex-switchboard switch --profile-key "$PROFILE_KEY" --surface cli --json
```

Use `--surface desktop` or `--surface both` only when that target was requested. Add `--stop-consumers` only after explicit authorization.

6. Verify:

```bash
codex-switchboard status --json --surface cli \
  | jq --arg key "$PROFILE_KEY" '.surfaces[] | select(.kind == "cli") | {kind, active_profile_key, matched: (.active_profile_key == $key)}'
```

If `matched` is not `true`, treat the switch as failed and report the blocker.

## Auto-swap Workflow

Use auto-swap when the user has asked for low-quota failover rather than one specific profile.

1. Inspect the current policy and decisions:

```bash
codex-switchboard autoswap status --json \
  | jq '{policy, decisions: [.decisions[] | {surface, decision, reason, active_profile_key, candidate_profile_key}]}'
```

2. Enable policy only when explicitly requested:

```bash
codex-switchboard autoswap enable --surface cli --json
```

3. Dry-run the policy decision:

```bash
codex-switchboard autoswap run-once --surface cli --json --dry-run \
  | jq '{consumer_count, decisions: [.decisions[] | {surface, decision, reason, active_profile_key, candidate_profile_key}]}'
```

4. Execute only through the policy engine:

```bash
codex-switchboard autoswap run-once --surface cli --json
```

Add `--stop-consumers` only when the caller explicitly authorized stopping running Codex consumers. If the result is `blocked`, report the `reason` and do not manually edit auth files.

## Pressure Scenario

An orchestrator says: "A Codex CLI agent exhausted its current account. Put it back to work if a paid account has tokens."

Correct behavior:

- Run `doctor --json` and redacted `status --json --paid-only --usable-only`.
- Select a paid usable profile by `score`.
- If consumers are running, either run `switch` without `--stop-consumers` and report the refusal, or ask/confirm before stopping consumers.
- Verify `active_profile_key` after a successful switch.
- Do not print token fields, raw auth files, or full unredacted account dumps.

Incorrect behavior:

- Reading `auth.json` into chat.
- Choosing a free plan because it has reset sooner.
- Using `--stop-consumers` without explicit authorization.
- Claiming success without verifying the active profile.
