# Noctalia AI Usage Monitor

A user-local Noctalia Shell plugin that shows AI quota usage in the bar and in a SmartPanel-style popup.

The plugin currently tracks Codex, OpenCode Go, Claude Code, and Cursor quota windows where local data is available. It focuses on quota percentages and reset times rather than token counts or estimated cost.

## Features

- Compact Noctalia bar widget with provider summaries.
- Popup panel with provider cards, quota bars, reset times, source status, and detail rows.
- Toggle button for switching the display between `remaining` and `used`.
- Manual refresh from the panel or the bar widget context menu.
- Hover tooltip with per-provider status, last refresh time, and stale state.
- Local cache output for reuse and stale fallback.

## Files

```text
manifest.json
Main.qml
BarWidget.qml
Panel.qml
scripts/ai-usage-collector
scripts/ai-usage-collector.js
```

Runtime cache files are written under:

```text
~/.cache/noctalia-ai-usage/latest.json
~/.cache/noctalia-ai-usage/claude-rate-limits.json
~/.cache/noctalia-ai-usage/claude-oauth-usage.json
~/.cache/noctalia-ai-usage/cursor-usage.json
```

## Installation

Place this repository at:

```text
~/.config/noctalia/plugins/ai-usage-monitor
```

Then enable the plugin in your Noctalia plugin configuration and add the bar widget where you want it to appear.

This plugin is intended to be user-local. It does not patch `/etc/xdg/quickshell/noctalia-shell`.

## Usage

- Left click the bar widget to open or close the plugin panel.
- Right click the bar widget to open the context menu and refresh now.
- Hover the bar widget to see provider status rows.
- In the panel, use the swap button to flip between `remaining` and `used`.
- In the panel, use the refresh button to run the collector immediately.

The bar summary uses the active representation, so switching from `remaining` to `used` updates the panel, tooltip, and bar text together.

## Settings

Default settings are defined in `manifest.json`:

```json
{
  "refreshIntervalMs": 60000,
  "staleAfterMs": 600000,
  "timezone": "UTC",
  "showCosts": true,
  "showUsedOnlyProvidersInBar": true
}
```

`AI_USAGE_TIMEZONE` is passed to the collector from the plugin setting.

`panelLayoutStyle` controls the popup quota-window rendering. Supported values are:

- `default`
- `meterRows`
- `tiles`
- `segmentedTiles`
- `animatedTiles`

## Providers

### Codex

Codex data is read from recent JSONL session files under:

```text
~/.codex/sessions
```

The collector looks for `rate_limits` payloads from `token_count` events and shows the available quota windows, typically:

- `5h`
- `7d`

Codex is marked stale when no fresh rate-limit payload has been emitted recently.

### OpenCode Go

OpenCode Go can report rolling, weekly, and monthly quota windows when dashboard access is configured.

Configuration is read from either environment variables:

```text
OPENCODE_GO_WORKSPACE_ID
OPENCODE_GO_AUTH_COOKIE
OPENCODE_GO_COOKIE_HEADER
```

Or from:

```text
~/.config/opencode/opencode-quota/opencode-go.json
```

The collector supports the `@slkiser/opencode-quota` helper when installed under `~/.config/opencode`, and can also use a full browser cookie header for the OpenCode Go dashboard.

### Claude Code

Claude Code data is read first from:

```text
~/.cache/noctalia-ai-usage/claude-rate-limits.json
```

That file can be populated by a Claude Code statusline command when Claude sends a `rate_limits` object.

If no statusline cache is available, the collector attempts to read local Claude OAuth credentials and fetch usage from the Claude OAuth usage endpoint. Successful responses are cached briefly in:

```text
~/.cache/noctalia-ai-usage/claude-oauth-usage.json
```

Failures are cooled down and reported in the UI as timeout, rate-limit, auth, or generic error states.

### Cursor

Cursor usage is read from local Cursor authentication and Cursor usage endpoints. On Linux, the collector looks for:

```text
~/.config/Cursor/sentry/*.json
~/.config/Cursor/User/globalStorage/storage.json
~/.config/Cursor/User/globalStorage/state.vscdb
```

The collector reads `cursorAuth/accessToken` from Cursor's SQLite state database using `sqlite3`, with a Python `sqlite3` fallback when available. It then queries Cursor's current-period usage endpoint and falls back to the usage-summary or legacy request-count endpoint when needed.

Cursor is shown as separate `Auto + Composer` and `API` billing-cycle quota windows when Cursor reports split usage percentages. Older or partial responses fall back to a single `Cycle` window. Successful responses are cached briefly in:

```text
~/.cache/noctalia-ai-usage/cursor-usage.json
```

Optional overrides are available for non-standard installs:

```text
CURSOR_CONFIG_DIR
CURSOR_DB_PATH
CURSOR_USER_ID
CURSOR_ACCESS_TOKEN
CURSOR_COOKIE_HEADER
CURSOR_SESSION_COOKIE
```

Cursor support uses unofficial personal usage endpoints, so endpoint or response-shape changes are reported as stale-cache, auth, timeout, rate-limit, or generic error states.

## Collector

The collector entrypoint is:

```bash
scripts/ai-usage-collector
```

The executable shell wrapper prepares the cache paths, timezone, and optional `nvm` environment, then runs the Node implementation in `scripts/ai-usage-collector.js`.

It:

- Sources `~/.nvm/nvm.sh` when available and runs `nvm use node`.
- Emits JSON to stdout.
- Writes `latest.json` with provider status, quota windows, cache state, and stale information.
- Redacts credentials from error messages.
- Writes cache files with mode `0600`.
- Does not print bearer tokens or auth cookies.

Run it manually with:

```bash
scripts/ai-usage-collector | jq .
```

## Validation

Useful checks:

```bash
bash -n scripts/ai-usage-collector
node --check scripts/ai-usage-collector.js
scripts/ai-usage-collector | jq .
jq . manifest.json
jq . ~/.cache/noctalia-ai-usage/latest.json
```

If `qmllint` is available, run it against the QML files. Otherwise, validate by reloading Noctalia and checking that the plugin loads, the bar widget renders, and the panel opens.

## License

MIT. See `LICENSE.md`.
