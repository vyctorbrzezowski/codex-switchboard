#!/usr/bin/env node
import crypto from "node:crypto";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { execFileSync } from "node:child_process";

const repoRoot = process.cwd();
const logDir = process.env.AUTH_WATCH_LOG_DIR || path.join(repoRoot, "logs");
const startedAt = new Date().toISOString().replace(/[:.]/g, "-");
const logPath = process.env.AUTH_WATCH_LOG || path.join(logDir, `auth-watch-${startedAt}.jsonl`);
const intervalMs = Number(process.env.AUTH_WATCH_INTERVAL_MS || 1000);
const heartbeatMs = Number(process.env.AUTH_WATCH_HEARTBEAT_MS || 10_000);
const home = os.homedir();
const activeAuthPath = path.join(home, ".codex", "auth.json");
const switchboardRoot = path.join(home, "Library", "Application Support", "CodexSwitchboard");
const profilesRoot = path.join(switchboardRoot, "profiles");
const accountsPath = path.join(switchboardRoot, "accounts.json");

fs.mkdirSync(logDir, { recursive: true });

let lastSignature = "";
let lastHeartbeat = 0;
let lastReason = "start";

function readJSON(file) {
  try {
    return JSON.parse(fs.readFileSync(file, "utf8"));
  } catch {
    return null;
  }
}

function stat(file) {
  try {
    const value = fs.statSync(file);
    return {
      exists: true,
      mtime: value.mtime.toISOString(),
      size: value.size,
    };
  } catch {
    return { exists: false, mtime: null, size: 0 };
  }
}

function sha(value) {
  if (!value) return "";
  return crypto.createHash("sha256").update(value).digest("hex").slice(0, 16);
}

function decodeBase64URL(value) {
  let normalized = String(value || "").replace(/-/g, "+").replace(/_/g, "/");
  normalized += "=".repeat((4 - (normalized.length % 4)) % 4);
  return Buffer.from(normalized, "base64");
}

function jwtPayload(token) {
  try {
    const pieces = String(token || "").split(".");
    if (pieces.length < 2) return {};
    return JSON.parse(decodeBase64URL(pieces[1]).toString("utf8"));
  } catch {
    return {};
  }
}

function expDate(payload) {
  return typeof payload.exp === "number" ? new Date(payload.exp * 1000).toISOString() : null;
}

function tokenSummary(token) {
  const payload = jwtPayload(token);
  return {
    hash: sha(token),
    exp: expDate(payload),
    sub: payload.sub || "",
    email: String(payload.email || "").toLowerCase(),
  };
}

function authSummary(file) {
  const root = readJSON(file);
  const tokens = root?.tokens || {};
  const id = tokenSummary(tokens.id_token);
  const access = tokenSummary(tokens.access_token);
  return {
    file,
    stat: stat(file),
    authMode: root?.auth_mode || "",
    lastRefresh: root?.last_refresh || "",
    email: id.email,
    sub: id.sub,
    accountId: tokens.account_id || "",
    idToken: { hash: id.hash, exp: id.exp },
    accessToken: { hash: access.hash, exp: access.exp },
    refreshToken: { hash: sha(tokens.refresh_token) },
  };
}

function accountsSummary() {
  const root = readJSON(accountsPath);
  const profiles = root?.profiles || {};
  return Object.entries(profiles).map(([key, value]) => ({
    key,
    email: String(value.email || "").toLowerCase(),
    accountId: value.accountId || "",
    expires: value.expires || 0,
    accessHash: sha(value.access),
    refreshHash: sha(value.refresh),
  }));
}

function capturedProfilesSummary() {
  if (!fs.existsSync(profilesRoot)) return [];
  return fs.readdirSync(profilesRoot)
    .flatMap((name) => {
      const profileDir = path.join(profilesRoot, name);
      const authFile = path.join(profileDir, "auth.json");
      if (!fs.existsSync(authFile)) return [];
      const meta = readJSON(path.join(profileDir, "meta.json")) || {};
      const auth = authSummary(authFile);
      return [{
        name,
        sourceProfileKey: meta.source_profile_key || "",
        metaEmail: String(meta.email || "").toLowerCase(),
        metaAccountId: meta.account_id || "",
        metaExpiresAt: meta.expires_at || 0,
        auth,
      }];
    })
    .sort((a, b) => a.name.localeCompare(b.name));
}

function processSummary() {
  const patterns = [
    "CodexSwitchboard",
    "Codex.app",
    "Codex Helper",
    "codex app-server",
  ];
  const results = {};
  for (const pattern of patterns) {
    try {
      results[pattern] = execFileSync("/usr/bin/pgrep", ["-fl", pattern], {
        encoding: "utf8",
        stdio: ["ignore", "pipe", "ignore"],
      }).trim().split("\n").filter(Boolean);
    } catch {
      results[pattern] = [];
    }
  }
  return results;
}

function matchingProfiles(active, profiles) {
  return profiles
    .filter((profile) => {
      const auth = profile.auth;
      return (active.sub && auth.sub === active.sub)
        || (active.accountId && auth.accountId === active.accountId)
        || (active.email && auth.email === active.email);
    })
    .map((profile) => ({
      name: profile.name,
      sourceProfileKey: profile.sourceProfileKey,
      sameAccess: profile.auth.accessToken.hash === active.accessToken.hash,
      sameRefresh: profile.auth.refreshToken.hash === active.refreshToken.hash,
      auth: profile.auth,
    }));
}

function snapshot(reason) {
  const active = authSummary(activeAuthPath);
  const profiles = capturedProfilesSummary();
  const accounts = accountsSummary();
  const event = {
    ts: new Date().toISOString(),
    reason,
    active,
    activeMatches: matchingProfiles(active, profiles),
    accounts,
    profiles,
    processes: processSummary(),
  };
  return event;
}

function stableSignature(event) {
  return JSON.stringify({
    active: event.active,
    activeMatches: event.activeMatches.map((match) => ({
      name: match.name,
      sameAccess: match.sameAccess,
      sameRefresh: match.sameRefresh,
      accessHash: match.auth.accessToken.hash,
      refreshHash: match.auth.refreshToken.hash,
      mtime: match.auth.stat.mtime,
    })),
    accounts: event.accounts.map((account) => ({
      key: account.key,
      accessHash: account.accessHash,
      refreshHash: account.refreshHash,
      expires: account.expires,
    })),
    profiles: event.profiles.map((profile) => ({
      name: profile.name,
      accessHash: profile.auth.accessToken.hash,
      refreshHash: profile.auth.refreshToken.hash,
      expires: profile.auth.accessToken.exp || profile.auth.idToken.exp,
      mtime: profile.auth.stat.mtime,
    })),
    processes: event.processes,
  });
}

function writeEvent(event, changed) {
  fs.appendFileSync(logPath, `${JSON.stringify(event)}\n`);
  const active = event.active;
  const matchText = event.activeMatches
    .map((match) => `${match.name}:access=${match.sameAccess ? "same" : "diff"},refresh=${match.sameRefresh ? "same" : "diff"}`)
    .join(" | ") || "no-match";
  console.log([
    `[${event.ts}] ${changed ? "CHANGE" : "HEARTBEAT"} ${event.reason}`,
    `active=${active.email || "?"} acct=${active.accountId || "?"} access=${active.accessToken.hash || "-"} refresh=${active.refreshToken.hash || "-"} accessExp=${active.accessToken.exp || "-"} idExp=${active.idToken.exp || "-"}`,
    `matches=${matchText}`,
    `log=${logPath}`,
  ].join("\n"));
}

function tick(reason = "poll") {
  const event = snapshot(reason);
  const signature = stableSignature(event);
  const now = Date.now();
  const changed = signature !== lastSignature;
  const heartbeat = now - lastHeartbeat >= heartbeatMs;
  if (changed || heartbeat) {
    writeEvent(event, changed);
    lastHeartbeat = now;
    lastSignature = signature;
  }
}

function watchPath(file, label) {
  try {
    fs.watch(file, { persistent: true, recursive: false }, (_event, filename) => {
      lastReason = `${label}:${filename || ""}`;
      tick(lastReason);
    });
  } catch {
    // Polling still catches changes.
  }
}

if (process.argv.includes("--once")) {
  const event = snapshot("once");
  writeEvent(event, true);
  process.exit(0);
}

console.log(`Writing auth diagnostics to ${logPath}`);
console.log("No raw token values are logged, only hashes and metadata.");
watchPath(path.dirname(activeAuthPath), "active-auth-dir");
watchPath(profilesRoot, "switchboard-profiles");
watchPath(switchboardRoot, "switchboard-root");
tick("start");
const timer = setInterval(() => tick(lastReason), intervalMs);

process.on("SIGINT", () => {
  clearInterval(timer);
  tick("stop");
  process.exit(0);
});
