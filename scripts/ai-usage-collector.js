const fs = require("fs");
const path = require("path");
const { pathToFileURL } = require("url");

const latestFile = process.env.LATEST_FILE;
const claudeFile = process.env.CLAUDE_FILE;
const claudeOauthFile = process.env.CLAUDE_OAUTH_FILE;
const updatedAt = process.env.UPDATED_AT;
const home = process.env.HOME || "";
const configHome = process.env.XDG_CONFIG_HOME || path.join(home, ".config");
const now = Date.now();
const CLAUDE_OAUTH_CACHE_TTL_MS = 5 * 60 * 1000;
const CLAUDE_OAUTH_ERROR_COOLDOWN_MS = 5 * 60 * 1000;
const ALL_PROVIDER_IDS = ["codex", "opencode-go", "claude"];

function enabledProviderSet() {
  const raw = process.env.AI_USAGE_ENABLED_PROVIDERS;
  if (raw === undefined) return new Set(ALL_PROVIDER_IDS);
  return new Set(String(raw).split(",").map(value => value.trim()).filter(Boolean));
}

const enabledProviders = enabledProviderSet();

function isProviderEnabled(id) {
  return enabledProviders.has(id);
}

function readJsonFile(filePath) {
  if (!filePath) return null;
  try {
    return JSON.parse(fs.readFileSync(filePath, "utf8"));
  } catch (_) {
    return null;
  }
}

function num(value) {
  if (value === null || value === undefined || value === "") return null;
  const n = Number(value);
  return Number.isFinite(n) ? n : null;
}

function str(value) {
  if (value === null || value === undefined || value === "") return null;
  return String(value);
}

function firstNumber(obj, keys) {
  if (!obj) return null;
  for (const key of keys) {
    const value = num(obj[key]);
    if (value !== null) return value;
  }
  return null;
}

function firstString(obj, keys) {
  if (!obj) return null;
  for (const key of keys) {
    const value = str(obj[key]);
    if (value !== null) return value;
  }
  return null;
}

function clampPercent(value) {
  if (value === null || value === undefined) return null;
  return Math.max(0, Math.min(100, value));
}

function safeReason(value, fallback = "Unavailable") {
  const text = str(value) || fallback;
  return text
    .replace(/Bearer\s+[A-Za-z0-9._~+/=-]+/gi, "[redacted credential]")
    .replace(/auth=([^;\s]+)/gi, "auth=[redacted]")
    .replace(/(accessToken|refreshToken|authCookie|Authorization|Cookie)["':=\s]+[^,\s}]+/gi, "credential=[redacted]")
    .replace(/\s+/g, " ")
    .trim()
    .slice(0, 180);
}

function normalizeTimestamp(value) {
  if (value === null || value === undefined || value === "") return null;
  if (typeof value === "number") {
    const ms = value > 100000000000 ? value : value * 1000;
    return new Date(ms).toISOString();
  }
  const asNumber = Number(value);
  if (Number.isFinite(asNumber) && String(value).match(/^\d+$/)) {
    const ms = asNumber > 100000000000 ? asNumber : asNumber * 1000;
    return new Date(ms).toISOString();
  }
  return String(value);
}

function resetValue(obj) {
  return firstString(obj, [
    "reset_at",
    "resetAt",
    "resets_at",
    "resetsAt",
    "resetTimeIso",
    "reset_time_iso",
    "window_reset_at",
    "next_reset_at"
  ]) || firstNumber(obj, [
    "reset_at",
    "resetAt",
    "resets_at",
    "resetsAt",
    "resetTimeIso",
    "reset_time_iso",
    "window_reset_at",
    "next_reset_at"
  ]);
}

function rateLimitWindow(rateLimits, names) {
  if (!rateLimits) return null;
  for (const name of names) {
    if (rateLimits[name]) return rateLimits[name];
  }
  return null;
}

function normalizeWindow(windowData) {
  if (!windowData) return null;

  let usedPercent = firstNumber(windowData, [
    "used_percent",
    "used_percentage",
    "usedPercent",
    "usagePercent",
    "utilization",
    "percent_used",
    "used"
  ]);
  let remainingPercent = firstNumber(windowData, [
    "remaining_percent",
    "remaining_percentage",
    "remainingPercent",
    "percentRemaining",
    "percent_remaining",
    "remaining"
  ]);

  if (remainingPercent === null && usedPercent !== null) {
    remainingPercent = 100 - usedPercent;
  } else if (usedPercent === null && remainingPercent !== null) {
    usedPercent = 100 - remainingPercent;
  }

  usedPercent = clampPercent(usedPercent);
  remainingPercent = clampPercent(remainingPercent);

  const resetAt = normalizeTimestamp(resetValue(windowData));
  const resetMs = resetAt ? Date.parse(resetAt) : NaN;
  if (Number.isFinite(resetMs) && resetMs <= now && remainingPercent !== null) {
    usedPercent = 0;
    remainingPercent = 100;
  }

  return {
    usedPercent,
    remainingPercent,
    resetAt: Number.isFinite(resetMs) && resetMs > now ? resetAt : null,
    windowMinutes: firstNumber(windowData, ["window_minutes", "windowMinutes", "minutes"])
  };
}

function makeQuotaWindow(id, label, normalized) {
  if (!normalized || normalized.remainingPercent === null) return null;
  return {
    id,
    label,
    usedPercent: normalized.usedPercent,
    remainingPercent: normalized.remainingPercent,
    resetAt: normalized.resetAt
  };
}

function firstWindow(windows, id) {
  if (!Array.isArray(windows)) return null;
  return windows.find(window => window && window.id === id) || null;
}

function ageSeconds(ageMs) {
  return Number.isFinite(ageMs) ? Math.max(0, Math.round(ageMs / 1000)) : null;
}

function listJsonlFiles(rootDir, maxAgeMs) {
  const files = [];
  const cutoff = now - maxAgeMs;

  function walk(dir) {
    let entries;
    try {
      entries = fs.readdirSync(dir, { withFileTypes: true });
    } catch (_) {
      return;
    }

    for (const entry of entries) {
      const filePath = path.join(dir, entry.name);
      if (entry.isDirectory()) {
        walk(filePath);
        continue;
      }
      if (!entry.isFile() || !entry.name.endsWith(".jsonl")) continue;

      try {
        const stat = fs.statSync(filePath);
        if (stat.mtimeMs >= cutoff) files.push(filePath);
      } catch (_) {}
    }
  }

  walk(rootDir);
  return files;
}

function latestCodexRateLimits() {
  const sessionsDir = path.join(home, ".codex", "sessions");
  const files = listJsonlFiles(sessionsDir, 21 * 24 * 60 * 60 * 1000);
  let latest = null;

  for (const file of files) {
    let text;
    try {
      text = fs.readFileSync(file, "utf8");
    } catch (_) {
      continue;
    }

    for (const line of text.split("\n")) {
      if (!line.includes('"rate_limits"')) continue;

      let record;
      try {
        record = JSON.parse(line);
      } catch (_) {
        continue;
      }

      const rateLimits = record && record.payload && record.payload.rate_limits;
      if (!rateLimits || (rateLimits.limit_id && rateLimits.limit_id !== "codex")) continue;

      const timestampMs = Date.parse(record.timestamp || "");
      if (!Number.isFinite(timestampMs)) continue;
      if (latest && timestampMs <= latest.timestampMs) continue;

      latest = {
        timestampMs,
        timestamp: new Date(timestampMs).toISOString(),
        rateLimits
      };
    }
  }

  return latest;
}

function codexProvider() {
  const base = {
    id: "codex",
    label: "Codex",
    mode: "exact-remaining",
    period: "5-hour",
    usedPercent: null,
    remainingPercent: null,
    weeklyRemainingPercent: null,
    monthlyRemainingPercent: null,
    resetAt: null,
    weeklyResetAt: null,
    monthlyResetAt: null,
    windows: [],
    source: "codex session rate_limits",
    available: false,
    stale: false,
    staleReason: "Codex rate limits appear after Codex records a token_count event"
  };

  const latest = latestCodexRateLimits();
  if (!latest) return base;

  const primary = normalizeWindow(latest.rateLimits.primary);
  const secondary = normalizeWindow(latest.rateLimits.secondary);
  if (!primary || primary.remainingPercent === null) return base;
  const windows = [
    makeQuotaWindow("five_hour", "5h", primary),
    makeQuotaWindow("weekly", "7d", secondary)
  ].filter(Boolean);

  const ageMs = now - latest.timestampMs;
  return {
    ...base,
    usedPercent: primary.usedPercent,
    remainingPercent: primary.remainingPercent,
    weeklyRemainingPercent: secondary ? secondary.remainingPercent : null,
    monthlyRemainingPercent: null,
    resetAt: primary.resetAt,
    weeklyResetAt: secondary ? secondary.resetAt : null,
    monthlyResetAt: null,
    windows,
    available: true,
    stale: ageMs > 15 * 60 * 1000,
    staleReason: ageMs > 15 * 60 * 1000 ? "Codex has not emitted fresh rate limit data recently" : null,
    cacheUpdatedAt: latest.timestamp,
    planType: latest.rateLimits.plan_type || null
  };
}

function readClaudeRateLimits() {
  const data = readJsonFile(claudeFile);
  if (!data) return { data: null, cachedAt: null };

  let cachedAt = null;
  try {
    cachedAt = fs.statSync(claudeFile).mtime.toISOString();
  } catch (_) {}

  if (data.rate_limits) return { data: data.rate_limits, cachedAt: data.updatedAt || cachedAt };
  return { data, cachedAt };
}

function readClaudeOauthCache() {
  const data = readJsonFile(claudeOauthFile);
  if (!data) return { data: null, cachedAt: null, ageMs: Infinity, errorAgeMs: Infinity, errorReason: null };

  const cachedAt = normalizeTimestamp(data.updatedAt);
  const cachedMs = cachedAt ? Date.parse(cachedAt) : NaN;
  const errorAt = normalizeTimestamp(data.lastErrorAt);
  const errorMs = errorAt ? Date.parse(errorAt) : NaN;
  return {
    data: data.usage || null,
    cachedAt,
    ageMs: Number.isFinite(cachedMs) ? now - cachedMs : Infinity,
    errorAgeMs: Number.isFinite(errorMs) ? now - errorMs : Infinity,
    errorReason: str(data.lastErrorReason)
  };
}

function writeClaudeOauthCache(data) {
  if (!data) return;
  try {
    fs.writeFileSync(claudeOauthFile, JSON.stringify({
      updatedAt,
      usage: data
    }, null, 2) + "\n", { mode: 0o600 });
  } catch (_) {}
}

function writeClaudeOauthError(reason) {
  const existing = readJsonFile(claudeOauthFile) || {};
  try {
    fs.writeFileSync(claudeOauthFile, JSON.stringify({
      updatedAt: existing.updatedAt || null,
      usage: existing.usage || null,
      lastErrorAt: updatedAt,
      lastErrorReason: safeReason(reason, "Claude OAuth usage endpoint unavailable")
    }, null, 2) + "\n", { mode: 0o600 });
  } catch (_) {}
}

function claudeOauthFailureKind(reason) {
  const text = String(reason || "").toLowerCase();
  if (text.includes("timed out") || text.includes("timeout")) return "timeout";
  if (text.includes("429") || text.includes("rate") || text.includes("cooldown")) return "rate-limited";
  if (text.includes("expired") || text.includes("rejected credentials") || text.includes("401") || text.includes("403")) return "auth";
  return reason ? "error" : null;
}

function withClaudeCacheState(provider, state) {
  return {
    ...provider,
    cacheStatus: state.cacheStatus || null,
    cacheUpdatedAt: state.cacheUpdatedAt !== undefined ? state.cacheUpdatedAt : provider.cacheUpdatedAt,
    cacheAgeSeconds: state.cacheAgeSeconds !== undefined ? state.cacheAgeSeconds : null,
    retryAfterSeconds: state.retryAfterSeconds !== undefined ? state.retryAfterSeconds : null,
    failureKind: state.failureKind || null
  };
}

function claudeRateLimitRoot(data) {
  if (!data || typeof data !== "object") return null;
  return data.rate_limits || data.rateLimits || data.usage || data.oauth_usage || data.oauthUsage || data;
}

function claudeProviderFromRateLimits(data, cachedAt, source, staleReason) {
  const root = claudeRateLimitRoot(data);
  const base = {
    id: "claude",
    label: "Claude Code",
    mode: "exact-remaining",
    period: "5-hour",
    usedPercent: null,
    remainingPercent: null,
    weeklyRemainingPercent: null,
    monthlyRemainingPercent: null,
    resetAt: null,
    weeklyResetAt: null,
    monthlyResetAt: null,
    windows: [],
    source,
    available: false,
    stale: false,
    staleReason,
    cacheUpdatedAt: cachedAt
  };

  const fiveHour = normalizeWindow(rateLimitWindow(root, [
    "five_hour",
    "fiveHour",
    "5_hour",
    "five-hour",
    "hour_5"
  ]));
  const weekly = normalizeWindow(rateLimitWindow(root, [
    "seven_day",
    "sevenDay",
    "weekly",
    "week",
    "7_day",
    "seven-day"
  ]));

  if (!fiveHour || fiveHour.remainingPercent === null) return base;
  const windows = [
    makeQuotaWindow("five_hour", "5h", fiveHour),
    makeQuotaWindow("weekly", "7d", weekly)
  ].filter(Boolean);

  return {
    ...base,
    usedPercent: fiveHour.usedPercent,
    remainingPercent: fiveHour.remainingPercent,
    weeklyRemainingPercent: weekly ? weekly.remainingPercent : null,
    monthlyRemainingPercent: null,
    resetAt: fiveHour.resetAt,
    weeklyResetAt: weekly ? weekly.resetAt : null,
    monthlyResetAt: null,
    windows,
    available: true,
    staleReason: null
  };
}

function claudeOauthAccessToken() {
  const credentialsPath = path.join(home, ".claude", ".credentials.json");
  const credentials = readJsonFile(credentialsPath);
  const oauth = credentials && credentials.claudeAiOauth;
  const token = oauth && str(oauth.accessToken);
  if (!token) {
    return {
      token: null,
      reason: "Claude OAuth credentials are missing; run claude auth login or start Claude Code"
    };
  }

  const expiresAt = normalizeTimestamp(oauth.expiresAt);
  const expiresMs = expiresAt ? Date.parse(expiresAt) : NaN;
  if (Number.isFinite(expiresMs) && expiresMs <= now + 30 * 1000) {
    return {
      token: null,
      reason: "Claude OAuth access token is expired; run claude auth login or start Claude Code"
    };
  }

  return { token, reason: null };
}

async function fetchClaudeOauthRateLimits() {
  const auth = claudeOauthAccessToken();
  if (!auth.token) return { data: null, cachedAt: null, reason: auth.reason };

  const controller = new AbortController();
  const timeout = setTimeout(() => controller.abort(), 8000);
  try {
    const response = await fetch("https://api.anthropic.com/api/oauth/usage", {
      method: "GET",
      headers: {
        Authorization: `Bearer ${auth.token}`,
        "anthropic-beta": "oauth-2025-04-20"
      },
      signal: controller.signal
    });

    if (!response.ok) {
      const reason = response.status === 401 || response.status === 403
        ? "Claude OAuth usage endpoint rejected credentials; run claude auth login or start Claude Code"
        : `Claude OAuth usage endpoint returned HTTP ${response.status}`;
      writeClaudeOauthError(reason);
      return { data: null, cachedAt: null, reason };
    }

    const data = await response.json();
    writeClaudeOauthCache(data);
    return { data, cachedAt: updatedAt, reason: null };
  } catch (err) {
    const reason = safeReason(
      err && err.name === "AbortError" ? "Claude OAuth usage endpoint timed out" : err && err.message,
      "Claude OAuth usage endpoint failed"
    );
    writeClaudeOauthError(reason);
    return {
      data: null,
      cachedAt: null,
      reason
    };
  } finally {
    clearTimeout(timeout);
  }
}

async function claudeProvider() {
  const cached = readClaudeRateLimits();
  const statusline = claudeProviderFromRateLimits(
    cached.data,
    cached.cachedAt,
    "claude statusLine rate_limits",
    "Claude rate limits appear after Claude Code provides statusline input"
  );
  if (statusline.available) {
    return withClaudeCacheState(statusline, {
      cacheStatus: cached.cachedAt ? "statusline-cache" : "live",
      cacheUpdatedAt: cached.cachedAt,
      cacheAgeSeconds: cached.cachedAt ? ageSeconds(now - Date.parse(cached.cachedAt)) : null
    });
  }

  const oauthCache = readClaudeOauthCache();
  if (oauthCache.data && oauthCache.ageMs <= CLAUDE_OAUTH_CACHE_TTL_MS) {
    return withClaudeCacheState(claudeProviderFromRateLimits(
      oauthCache.data,
      oauthCache.cachedAt,
      "Claude OAuth usage endpoint cache",
      null
    ), {
      cacheStatus: "cached",
      cacheUpdatedAt: oauthCache.cachedAt,
      cacheAgeSeconds: ageSeconds(oauthCache.ageMs)
    });
  }
  if (!oauthCache.data && oauthCache.errorAgeMs <= CLAUDE_OAUTH_ERROR_COOLDOWN_MS) {
    return withClaudeCacheState(claudeProviderFromRateLimits(
      null,
      null,
      "Claude OAuth usage endpoint",
      `${oauthCache.errorReason || "Claude OAuth usage endpoint is cooling down"}; retrying after short cooldown`
    ), {
      cacheStatus: "cooldown",
      retryAfterSeconds: Math.max(0, Math.ceil((CLAUDE_OAUTH_ERROR_COOLDOWN_MS - oauthCache.errorAgeMs) / 1000)),
      failureKind: claudeOauthFailureKind(oauthCache.errorReason)
    });
  }

  const oauth = await fetchClaudeOauthRateLimits();
  const live = claudeProviderFromRateLimits(
    oauth.data,
    oauth.cachedAt,
    "Claude OAuth usage endpoint",
    oauth.reason || statusline.staleReason
  );
  if (live.available) {
    return withClaudeCacheState(live, {
      cacheStatus: "live",
      cacheUpdatedAt: oauth.cachedAt,
      cacheAgeSeconds: 0
    });
  }

  if (oauthCache.data) {
    const fallback = claudeProviderFromRateLimits(
      oauthCache.data,
      oauthCache.cachedAt,
      "Claude OAuth usage endpoint cache",
      oauth.reason || "Claude OAuth usage endpoint unavailable"
    );
    if (fallback.available) {
      return withClaudeCacheState({
        ...fallback,
        stale: true,
        staleReason: oauth.reason || "Claude OAuth usage endpoint unavailable"
      }, {
        cacheStatus: "stale-cache",
        cacheUpdatedAt: oauthCache.cachedAt,
        cacheAgeSeconds: ageSeconds(oauthCache.ageMs),
        failureKind: claudeOauthFailureKind(oauth.reason)
      });
    }
  }

  return withClaudeCacheState(live, {
    cacheStatus: oauth.reason ? "error" : null,
    failureKind: claudeOauthFailureKind(oauth.reason)
  });
}

function openCodeGoBase(staleReason) {
  return {
    id: "opencode-go",
    label: "OpenCode Go",
    mode: "quota-unavailable",
    period: "5-hour/7-day/30-day",
    usedPercent: null,
    remainingPercent: null,
    weeklyRemainingPercent: null,
    monthlyRemainingPercent: null,
    resetAt: null,
    weeklyResetAt: null,
    monthlyResetAt: null,
    windows: [],
    source: "@slkiser/opencode-quota dashboard scrape",
    available: false,
    stale: false,
    staleReason
  };
}

function readOpenCodeGoConfig() {
  const configFile = path.join(configHome, "opencode", "opencode-quota", "opencode-go.json");
  const fileConfig = readJsonFile(configFile) || {};

  const workspaceId = (str(process.env.OPENCODE_GO_WORKSPACE_ID) || str(fileConfig.workspaceId) || "").trim();
  let authCookie = (str(process.env.OPENCODE_GO_AUTH_COOKIE) || str(fileConfig.authCookie) || "").trim();
  let cookieHeader = (str(process.env.OPENCODE_GO_COOKIE_HEADER) || str(fileConfig.cookieHeader) || "").trim();
  if (!cookieHeader && (/^auth=/i.test(authCookie) || authCookie.includes(";"))) {
    cookieHeader = authCookie;
    authCookie = "";
  }
  const missing = [];
  if (!workspaceId) missing.push("workspaceId");
  if (!authCookie && !cookieHeader) missing.push("dashboard auth value or browser auth header");

  return {
    workspaceId,
    authCookie,
    cookieHeader,
    configFile,
    missing
  };
}

async function loadOpenCodeGoQuery() {
  const modulePath = path.join(configHome, "opencode", "node_modules", "@slkiser", "opencode-quota", "dist", "lib", "opencode-go.js");
  if (!fs.existsSync(modulePath)) {
    return {
      query: null,
      reason: "@slkiser/opencode-quota@3.9.0 is not installed under ~/.config/opencode"
    };
  }

  try {
    const mod = await import(pathToFileURL(modulePath).href);
    if (typeof mod.queryOpenCodeGoQuota !== "function") {
      return { query: null, reason: "Installed opencode-quota package does not expose queryOpenCodeGoQuota" };
    }
    return { query: mod.queryOpenCodeGoQuota, reason: null };
  } catch (err) {
    return {
      query: null,
      reason: safeReason(err && err.message, "Could not load opencode-quota OpenCode Go helper")
    };
  }
}

function openCodeGoWindow(id, label, data) {
  return makeQuotaWindow(id, label, normalizeWindow(data));
}

function openCodeGoDashboardUrl(workspaceId) {
  return `https://opencode.ai/workspace/${encodeURIComponent(workspaceId)}/go`;
}

function openCodeGoWindowFromScrape(windowData) {
  const usagePercent = clampPercent(num(windowData && windowData.usagePercent));
  const resetInSec = Math.max(0, num(windowData && windowData.resetInSec) || 0);
  if (usagePercent === null) return null;
  return {
    usagePercent,
    percentRemaining: 100 - usagePercent,
    resetTimeIso: new Date(Date.now() + resetInSec * 1000).toISOString()
  };
}

function parseOpenCodeGoDashboardWindow(html, fieldName) {
  const number = String.raw`(-?\d+(?:\.\d+)?)`;
  const objectPattern = String.raw`${fieldName}:\$R\[\d+\]=\{[^}]*\}`;
  const objectMatch = new RegExp(objectPattern).exec(html);
  if (!objectMatch) return null;

  const usageMatch = new RegExp(String.raw`usagePercent:${number}`).exec(objectMatch[0]);
  const resetMatch = new RegExp(String.raw`resetInSec:${number}`).exec(objectMatch[0]);
  if (!usageMatch || !resetMatch) return null;

  return openCodeGoWindowFromScrape({
    usagePercent: usageMatch[1],
    resetInSec: resetMatch[1]
  });
}

function openCodeGoLoginReason(html) {
  const title = (html.match(/<title[^>]*>([^<]*)/i) || [])[1] || "";
  if (/openauth/i.test(title) || /sign in|login|continue with/i.test(html)) {
    return "OpenCode Go dashboard returned the login page; refresh the saved browser auth value or paste the full browser auth header";
  }
  return null;
}

async function fetchOpenCodeGoDashboard(workspaceId, cookieHeader) {
  const response = await fetch(openCodeGoDashboardUrl(workspaceId), {
    method: "GET",
    headers: {
      "User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) Gecko/20100101 Firefox/148.0",
      Accept: "text/html",
      Cookie: cookieHeader
    },
    signal: AbortSignal.timeout ? AbortSignal.timeout(10000) : undefined
  });
  const html = await response.text();
  return { response, html };
}

async function queryOpenCodeGoWithCookieHeader(workspaceId, cookieHeader) {
  const { response, html } = await fetchOpenCodeGoDashboard(workspaceId, cookieHeader);
  if (!response.ok) {
    return {
      success: false,
      error: `OpenCode Go dashboard returned HTTP ${response.status}`
    };
  }

  const loginReason = openCodeGoLoginReason(html);
  if (loginReason) return { success: false, error: loginReason };

  const rolling = parseOpenCodeGoDashboardWindow(html, "rollingUsage");
  const weekly = parseOpenCodeGoDashboardWindow(html, "weeklyUsage");
  const monthly = parseOpenCodeGoDashboardWindow(html, "monthlyUsage");
  if (!rolling && !weekly && !monthly) {
    return {
      success: false,
      error: "Could not parse OpenCode Go dashboard usage windows after authentication"
    };
  }

  return {
    success: true,
    ...(rolling ? { rolling } : {}),
    ...(weekly ? { weekly } : {}),
    ...(monthly ? { monthly } : {})
  };
}

async function diagnoseOpenCodeGoDashboard(workspaceId, authCookie) {
  try {
    const { html } = await fetchOpenCodeGoDashboard(workspaceId, `auth=${authCookie}`);
    return openCodeGoLoginReason(html);
  } catch (_) {
    return null;
  }
}

async function opencodeGoProvider() {
  const config = readOpenCodeGoConfig();
  if (config.missing.length > 0) {
    return openCodeGoBase(`OpenCode Go setup missing ${config.missing.join(" and ")} in ${config.configFile} or OPENCODE_GO_* env vars`);
  }

  let quota;
  if (config.cookieHeader) {
    try {
      quota = await queryOpenCodeGoWithCookieHeader(config.workspaceId, config.cookieHeader);
    } catch (err) {
      return openCodeGoBase(safeReason(err && err.message, "OpenCode Go dashboard query failed"));
    }
  } else {
    const loader = await loadOpenCodeGoQuery();
    if (!loader.query) return openCodeGoBase(loader.reason);

    try {
      quota = await loader.query(config.workspaceId, config.authCookie, { requestTimeoutMs: 10000 });
    } catch (err) {
      return openCodeGoBase(safeReason(err && err.message, "OpenCode Go dashboard query failed"));
    }
  }

  if (!quota || quota.success !== true) {
    if (config.authCookie && quota && /Could not parse any known OpenCode Go dashboard usage windows/.test(quota.error || "")) {
      const loginReason = await diagnoseOpenCodeGoDashboard(config.workspaceId, config.authCookie);
      if (loginReason) return openCodeGoBase(loginReason);
    }
    return openCodeGoBase(safeReason(quota && quota.error, "OpenCode Go dashboard query returned no quota data"));
  }

  const windows = [
    openCodeGoWindow("five_hour", "5h", quota.rolling),
    openCodeGoWindow("weekly", "7d", quota.weekly),
    openCodeGoWindow("monthly", "30d", quota.monthly)
  ].filter(Boolean);
  const primary = firstWindow(windows, "five_hour") || windows[0] || null;
  const weekly = firstWindow(windows, "weekly");
  const monthly = firstWindow(windows, "monthly");

  if (!primary) {
    return openCodeGoBase("OpenCode Go dashboard returned no recognized quota windows");
  }

  return {
    ...openCodeGoBase(null),
    mode: "exact-remaining",
    usedPercent: primary.usedPercent,
    remainingPercent: primary.remainingPercent,
    weeklyRemainingPercent: weekly ? weekly.remainingPercent : null,
    monthlyRemainingPercent: monthly ? monthly.remainingPercent : null,
    resetAt: primary.resetAt,
    weeklyResetAt: weekly ? weekly.resetAt : null,
    monthlyResetAt: monthly ? monthly.resetAt : null,
    windows,
    available: true,
    staleReason: null
  };
}

async function main() {
  const providers = [];
  if (isProviderEnabled("codex")) providers.push(codexProvider());
  if (isProviderEnabled("opencode-go")) providers.push(await opencodeGoProvider());
  if (isProviderEnabled("claude")) providers.push(await claudeProvider());

  const staleProviders = providers.filter(provider => provider.stale);
  const result = {
    updatedAt,
    stale: staleProviders.length > 0,
    staleReason: staleProviders.map(provider => provider.staleReason).filter(Boolean).join("; ") || null,
    providers
  };

  const output = JSON.stringify(result, null, 2) + "\n";
  fs.writeFileSync(latestFile, output, { mode: 0o600 });
  process.stdout.write(output);
}

main().catch(err => {
  const result = {
    updatedAt,
    stale: true,
    staleReason: safeReason(err && err.message, "collector failed"),
    providers: []
  };
  const output = JSON.stringify(result, null, 2) + "\n";
  try {
    fs.writeFileSync(latestFile, output, { mode: 0o600 });
  } catch (_) {}
  process.stdout.write(output);
  process.exitCode = 1;
});
