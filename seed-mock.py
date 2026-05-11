#!/usr/bin/env python3
"""Seed Codex Switchboard with 4 mock accounts and open the app."""

import json
import os
import shutil
import subprocess
from datetime import datetime, timezone, timedelta

HOME = os.path.expanduser("~")
APP_SUPPORT = os.path.join(HOME, "Library/Application Support/CodexSwitchboard")
PROFILES = os.path.join(APP_SUPPORT, "profiles")
CODEX_AUTH = os.path.join(HOME, ".codex/auth.json")

# Clean previous mock state if any
for d in [APP_SUPPORT]:
    if os.path.isdir(d):
        shutil.rmtree(d)
os.makedirs(APP_SUPPORT, mode=0o700, exist_ok=True)
os.makedirs(PROFILES, mode=0o700, exist_ok=True)

now = datetime.now(timezone.utc)

def iso(dt):
    return dt.strftime("%Y-%m-%dT%H:%M:%S.%f")[:-3] + "Z"

accounts_json = {
    "version": 1,
    "profiles": {},
    "order": {"default": []}
}

snapshot = {
    "lastRefreshEpoch": now.timestamp(),
    "accounts": []
}

# Define 4 mock accounts with varied states
mocks = [
    {
        "email": "alice@acme.corp",
        "accountId": "acc-alice-01",
        "workspace": "Acme Engineering",
        "plan": "team",
        "sessionFree": 82.0,
        "weeklyFree": 64.0,
        "sessionReset": 1800,
        "weeklyReset": 86400 * 2 + 3600 * 5,
        "hasError": False,
        "errorMessage": None,
        "active": False,
    },
    {
        "email": "bob@startup.io",
        "accountId": "acc-bob-02",
        "workspace": "startup.io",
        "plan": "plus",
        "sessionFree": 35.0,
        "weeklyFree": 12.0,
        "sessionReset": 7200,
        "weeklyReset": 3600 * 8,
        "hasError": False,
        "errorMessage": None,
        "active": True,
    },
    {
        "email": "charlie@freelance.dev",
        "accountId": "user-charlie-03",
        "workspace": "plus",
        "plan": "plus",
        "sessionFree": 8.0,
        "weeklyFree": 3.0,
        "sessionReset": 600,
        "weeklyReset": 1800,
        "hasError": False,
        "errorMessage": None,
        "active": False,
    },
    {
        "email": "diana@oldcorp.com",
        "accountId": "acc-diana-04",
        "workspace": "OldCorp",
        "plan": "team",
        "sessionFree": 0.0,
        "weeklyFree": 0.0,
        "sessionReset": 0,
        "weeklyReset": 86400 * 4,
        "hasError": True,
        "errorMessage": "Workspace deactivated",
        "active": False,
    },
]

def profile_key(m):
    scope = m["workspace"].lower().replace(" ", "-")
    return f"openai-codex:{scope}:{m['email']}"

def profile_name(m):
    return m["email"].replace("@", "_at_").replace(".", "_")

for m in mocks:
    key = profile_key(m)
    name = profile_name(m)
    pdir = os.path.join(PROFILES, name)
    os.makedirs(pdir, mode=0o700, exist_ok=True)

    # accounts.json profile entry
    accounts_json["profiles"][key] = {
        "access": f"mock_access_token_{m['accountId']}",
        "refresh": f"mock_refresh_token_{m['accountId']}",
        "expires": int((now + timedelta(days=30)).timestamp()),
        "provider": "openai-codex",
        "type": "oauth",
        "email": m["email"],
        "accountId": m["accountId"]
    }
    accounts_json["order"]["default"].append(key)

    # auth.json (captured profile format)
    auth = {
        "OPENAI_API_KEY": None,
        "auth_mode": "chatgpt",
        "last_refresh": iso(now),
        "tokens": {
            "id_token": f"mock_id_{m['accountId']}",
            "access_token": f"mock_access_{m['accountId']}",
            "refresh_token": f"mock_refresh_{m['accountId']}",
            "account_id": m["accountId"],
        }
    }
    # meta.json
    meta = {
        "email": m["email"],
        "account_id": m["accountId"],
        "source_profile_key": key,
        "captured_at": iso(now),
        "expires_at": int((now + timedelta(days=30)).timestamp()),
    }

    auth_path = os.path.join(pdir, "auth.json")
    meta_path = os.path.join(pdir, "meta.json")
    with open(auth_path, "w") as f:
        json.dump(auth, f, indent=2)
    with open(meta_path, "w") as f:
        json.dump(meta, f, indent=2)
    os.chmod(auth_path, 0o600)
    os.chmod(meta_path, 0o600)

    # snapshot account
    renewal = (now + timedelta(days=14)).isoformat() if not m["hasError"] else None
    snapshot["accounts"].append({
        "id": f"{m['email']}|{m['accountId']}",
        "profileKey": key,
        "email": m["email"],
        "workspace": m["workspace"],
        "plan": m["plan"],
        "sessionFree": m["sessionFree"],
        "weeklyFree": m["weeklyFree"],
        "sessionResetSeconds": m["sessionReset"],
        "weeklyResetSeconds": m["weeklyReset"],
        "planRenewalDate": renewal,
        "hasError": m["hasError"],
        "errorMessage": m["errorMessage"]
    })

    # If this is the active account, write ~/.codex/auth.json
    if m["active"]:
        os.makedirs(os.path.dirname(CODEX_AUTH), mode=0o700, exist_ok=True)
        with open(CODEX_AUTH, "w") as f:
            json.dump(auth, f, indent=2)
        os.chmod(CODEX_AUTH, 0o600)

# Write accounts.json and snapshot
accounts_path = os.path.join(APP_SUPPORT, "accounts.json")
snapshot_path = os.path.join(APP_SUPPORT, "accounts-snapshot.json")
with open(accounts_path, "w") as f:
    json.dump(accounts_json, f, indent=2)
with open(snapshot_path, "w") as f:
    json.dump(snapshot, f, indent=2)
os.chmod(accounts_path, 0o600)
os.chmod(snapshot_path, 0o600)

print("Mock data seeded.")
print("Opening CodexSwitchboard.app...")

# Open the local .app from the repo
app = os.path.join(os.path.dirname(os.path.abspath(__file__)), "dist/CodexSwitchboard.app")
subprocess.run(["open", app])
