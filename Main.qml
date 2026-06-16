import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons

Item {
  id: root

  required property var pluginApi

  property var providers: []
  property var historyByProvider: ({})
  property int historyVersion: 0
  property string summaryText: "Codex n/a Go n/a Claude n/a"
  property var tooltipRows: [["AI Usage", "Waiting for first refresh"]]
  property string lastUpdated: ""
  property bool isStale: false
  property string staleReason: ""
  property bool collectorRunning: false
  property var activeCollectorProcess: null
  property double collectorStartedAt: 0
  property int refreshVersion: 0
  property string representationMode: "remaining"
  property int settingsVersion: 0

  readonly property string collectorPath: pluginApi.pluginDir + "/scripts/ai-usage-collector"
  readonly property int refreshIntervalMs: Math.max(10000, pluginApi.pluginSettings.refreshIntervalMs || 60000)
  readonly property int collectorTimeoutMs: Math.max(10000, pluginApi.pluginSettings.collectorTimeoutMs || 30000)
  readonly property int staleAfterMs: pluginApi.pluginSettings.staleAfterMs || 600000
  readonly property string timezone: pluginApi.pluginSettings.timezone || "UTC"

  Component.onCompleted: refreshNow()

  Connections {
    target: root.pluginApi

    function onPluginSettingsChanged() {
      root.applySettings(false);
    }
  }

  Timer {
    interval: root.refreshIntervalMs
    repeat: true
    running: true
    triggeredOnStart: false
    onTriggered: root.refreshNow()
  }

  Timer {
    id: collectorTimeoutTimer

    interval: root.collectorTimeoutMs
    repeat: false
    onTriggered: root.cancelActiveCollector("collector timed out")
  }

  function providerSettings() {
    if (!pluginApi || !pluginApi.pluginSettings || !pluginApi.pluginSettings.providers)
      return {};
    return pluginApi.pluginSettings.providers;
  }

  function isProviderEnabled(id) {
    var settings = providerSettings();
    return settings[id] !== false;
  }

  function barWindowSettings() {
    if (!pluginApi || !pluginApi.pluginSettings || !pluginApi.pluginSettings.barWindows)
      return {};
    return pluginApi.pluginSettings.barWindows;
  }

  function isBarWindowEnabled(id) {
    var settings = barWindowSettings();
    return settings[id] !== false;
  }

  function anyBarWindowEnabled() {
    return isBarWindowEnabled("five_hour") || isBarWindowEnabled("weekly") || isBarWindowEnabled("monthly");
  }

  function useShortBarResetTime() {
    return pluginApi && pluginApi.pluginSettings && pluginApi.pluginSettings.shortBarResetTime === true;
  }

  function enabledProviderIds() {
    var ids = [];
    if (isProviderEnabled("codex"))
      ids.push("codex");
    if (isProviderEnabled("opencode-go"))
      ids.push("opencode-go");
    if (isProviderEnabled("claude"))
      ids.push("claude");
    return ids;
  }

  function filterEnabledProviders(items) {
    var rows = [];
    for (var i = 0; i < items.length; i++) {
      if (items[i] && isProviderEnabled(items[i].id))
        rows.push(items[i]);
    }
    return rows;
  }

  function applySettings(refresh) {
    providers = filterEnabledProviders(providers || []);
    settingsVersion++;
    rebuildSummary();
    rebuildTooltipRows();
    if (refresh === true)
      refreshNow();
  }

  function reloadSettings() {
    applySettings(true);
  }

  function refreshNow() {
    if (collectorRunning) {
      if (collectorStartedAt > 0 && Date.now() - collectorStartedAt > collectorTimeoutMs)
        cancelActiveCollector("previous collector timed out");
      else
        return false;
    }

    var ids = enabledProviderIds();
    if (ids.length === 0) {
      providers = [];
      lastUpdated = new Date().toISOString();
      isStale = false;
      staleReason = "";
      refreshVersion++;
      rebuildSummary();
      rebuildTooltipRows();
      return false;
    }

    collectorRunning = true;
    collectorStartedAt = Date.now();
    var proc = Qt.createQmlObject('import QtQuick; import Quickshell.Io; Process { stdout: StdioCollector {} }', root, "AiUsageCollector");
    activeCollectorProcess = proc;
    proc.command = ["env", "AI_USAGE_TIMEZONE=" + timezone, "AI_USAGE_ENABLED_PROVIDERS=" + ids.join(","), collectorPath];
    proc.exited.connect(function (exitCode) {
      if (proc !== root.activeCollectorProcess) {
        proc.destroy();
        return;
      }

      var text = String(proc.stdout.text || "");
      root.collectorRunning = false;
      root.collectorStartedAt = 0;
      root.activeCollectorProcess = null;
      collectorTimeoutTimer.stop();
      root.consumeCollectorOutput(text, exitCode);
      proc.destroy();
    });
    collectorTimeoutTimer.restart();
    proc.running = true;
    return true;
  }

  function cancelActiveCollector(reason) {
    var proc = activeCollectorProcess;
    activeCollectorProcess = null;
    collectorRunning = false;
    collectorStartedAt = 0;
    collectorTimeoutTimer.stop();

    if (proc) {
      try {
        if (proc.running)
          proc.signal(15);
      } catch (e) {}
      proc.destroy();
    }

    isStale = true;
    staleReason = reason || "collector stopped";
    refreshVersion++;
    rebuildSummary();
    rebuildTooltipRows();
  }

  function consumeCollectorOutput(text, exitCode) {
    if (exitCode !== 0 || text.trim() === "") {
      isStale = true;
      staleReason = exitCode !== 0 ? "collector exited " + exitCode : "collector returned no data";
      refreshVersion++;
      rebuildSummary();
      rebuildTooltipRows();
      return;
    }

    try {
      var data = JSON.parse(text);
      providers = filterEnabledProviders(data.providers || []);
      lastUpdated = data.updatedAt || "";
      var ageStale = isDataOlderThanStaleThreshold(data.updatedAt || "");
      isStale = data.stale === true || ageStale;
      staleReason = data.staleReason || (ageStale ? "data is older than " + Math.round(staleAfterMs / 60000) + " minutes" : "");
      appendHistory(providers);
      refreshVersion++;
      rebuildSummary();
      rebuildTooltipRows();
    } catch (e) {
      isStale = true;
      staleReason = "collector JSON parse failed";
      refreshVersion++;
      rebuildSummary();
      rebuildTooltipRows();
    }
  }

  function isDataOlderThanStaleThreshold(value) {
    if (!value)
      return false;
    var d = new Date(value);
    if (isNaN(d.getTime()))
      return false;
    return (Date.now() - d.getTime()) > staleAfterMs;
  }

  function appendHistory(items) {
    var next = Object.assign({}, historyByProvider);
    for (var i = 0; i < items.length; i++) {
      var provider = items[i];
      if (!provider || provider.available === false || !isProviderEnabled(provider.id))
        continue;

      var value = null;
      if (provider.mode === "exact-remaining") {
        var primary = primaryWindow(provider);
        value = primary ? primary.remainingPercent : provider.remainingPercent;
      }

      if (value === null || value === undefined || isNaN(value))
        continue;

      var arr = (next[provider.id] || []).slice();
      if (arr.length === 0) {
        for (var seed = 0; seed < 4; seed++)
          arr.push(value);
      } else {
        arr.push(value);
      }
      while (arr.length > 60)
        arr.shift();
      next[provider.id] = arr;
    }
    historyByProvider = next;
    historyVersion++;
  }

  function providerById(id) {
    if (!isProviderEnabled(id))
      return null;
    for (var i = 0; i < providers.length; i++) {
      if (providers[i].id === id)
        return providers[i];
    }
    return null;
  }

  function historyFor(id) {
    return historyByProvider[id] || [];
  }

  function historyMax(id) {
    var values = historyFor(id);
    var maxValue = 1;
    for (var i = 0; i < values.length; i++)
      maxValue = Math.max(maxValue, values[i] || 0);
    return maxValue;
  }

  function formatTime(value) {
    if (!value)
      return "n/a";
    var d = new Date(value);
    if (isNaN(d.getTime()))
      return value;
    return Qt.formatDateTime(d, "HH:mm");
  }

  function formatDateTime(value) {
    if (!value)
      return "n/a";
    var d = new Date(value);
    if (isNaN(d.getTime()))
      return value;
    return Qt.formatDateTime(d, "yyyy-MM-dd HH:mm:ss");
  }

  function formatRemaining(value) {
    if (value === null || value === undefined || isNaN(value))
      return "n/a";
    return Math.round(value) + "%";
  }

  function clampPercent(value) {
    if (value === null || value === undefined || isNaN(value))
      return null;
    return Math.max(0, Math.min(100, value));
  }

  function usedPercent(windowData) {
    if (!windowData)
      return null;
    var value = clampPercent(windowData.usedPercent);
    if (value !== null)
      return value;
    var remaining = clampPercent(windowData.remainingPercent);
    return remaining !== null ? 100 - remaining : null;
  }

  function remainingPercent(windowData) {
    if (!windowData)
      return null;
    var value = clampPercent(windowData.remainingPercent);
    if (value !== null)
      return value;
    var used = clampPercent(windowData.usedPercent);
    return used !== null ? 100 - used : null;
  }

  function representationName() {
    return representationMode === "used" ? "used" : "remaining";
  }

  function representationTitle() {
    return representationMode === "used" ? "Used" : "Remaining";
  }

  function alternateRepresentationName() {
    return representationMode === "used" ? "remaining" : "used";
  }

  function nextRepresentationName() {
    return representationMode === "used" ? "remaining" : "used";
  }

  function displayPercent(windowData) {
    return representationMode === "used" ? usedPercent(windowData) : remainingPercent(windowData);
  }

  function alternatePercent(windowData) {
    return representationMode === "used" ? remainingPercent(windowData) : usedPercent(windowData);
  }

  function displayPercentText(windowData) {
    return formatRemaining(displayPercent(windowData));
  }

  function alternatePercentText(windowData) {
    return formatRemaining(alternatePercent(windowData));
  }

  function flipRepresentation() {
    representationMode = representationMode === "used" ? "remaining" : "used";
    rebuildSummary();
    rebuildTooltipRows();
  }

  function formatSecondsShort(value) {
    if (value === null || value === undefined || isNaN(value))
      return "";
    var seconds = Math.max(0, Math.round(value));
    if (seconds < 60)
      return seconds + "s";
    return Math.ceil(seconds / 60) + "m";
  }

  function providerStateText(provider) {
    if (!provider)
      return "";
    if (provider.cacheStatus === "cooldown") {
      var retry = formatSecondsShort(provider.retryAfterSeconds);
      var prefix = provider.failureKind === "timeout" ? "Timeout cooldown" : (provider.failureKind === "rate-limited" ? "Rate limit cooldown" : "Cooldown");
      return retry ? prefix + " " + retry : prefix;
    }
    if (provider.failureKind === "timeout")
      return "Timed out";
    if (provider.failureKind === "rate-limited")
      return "Rate limited";
    if (provider.failureKind === "auth")
      return "Auth required";
    if (provider.cacheStatus === "stale-cache")
      return "Stale cache";
    if (provider.cacheStatus === "cached")
      return "Cached";
    if (provider.cacheStatus === "statusline-cache")
      return "Statusline cache";
    return "";
  }

  function quotaWindows(provider) {
    var rows = [];
    if (!provider)
      return rows;

    if (provider.windows && provider.windows.length !== undefined) {
      for (var i = 0; i < provider.windows.length; i++) {
        var windowData = provider.windows[i];
        if (!windowData || windowData.remainingPercent === null || windowData.remainingPercent === undefined || isNaN(windowData.remainingPercent))
          continue;
        rows.push(windowData);
      }
    }

    if (rows.length > 0 || provider.mode !== "exact-remaining")
      return rows;

    if (provider.remainingPercent !== null && provider.remainingPercent !== undefined && !isNaN(provider.remainingPercent)) {
      rows.push({
        id: "five_hour",
        label: "5h",
        remainingPercent: provider.remainingPercent,
        usedPercent: provider.usedPercent,
        resetAt: provider.resetAt
      });
    }
    if (provider.weeklyRemainingPercent !== null && provider.weeklyRemainingPercent !== undefined && !isNaN(provider.weeklyRemainingPercent)) {
      rows.push({
        id: "weekly",
        label: "7d",
        remainingPercent: provider.weeklyRemainingPercent,
        usedPercent: null,
        resetAt: provider.weeklyResetAt
      });
    }
    if (provider.monthlyRemainingPercent !== null && provider.monthlyRemainingPercent !== undefined && !isNaN(provider.monthlyRemainingPercent)) {
      rows.push({
        id: "monthly",
        label: "30d",
        remainingPercent: provider.monthlyRemainingPercent,
        usedPercent: null,
        resetAt: provider.monthlyResetAt
      });
    }
    return rows;
  }

  function barQuotaWindows(provider) {
    var rows = quotaWindows(provider);
    var visibleRows = [];
    for (var i = 0; i < rows.length; i++) {
      if (isBarWindowEnabled(rows[i].id))
        visibleRows.push(rows[i]);
    }
    return visibleRows;
  }

  function primaryWindow(provider) {
    var rows = quotaWindows(provider);
    for (var i = 0; i < rows.length; i++) {
      if (rows[i].id === "five_hour")
        return rows[i];
    }
    return rows.length > 0 ? rows[0] : null;
  }

  function isCompactMode() {
    return pluginApi.pluginSettings.compactMode === true;
  }

  function setCompactMode(enabled) {
    pluginApi.pluginSettings = Object.assign({}, pluginApi.pluginSettings || {}, {
      "compactMode": enabled === true
    });
    pluginApi.saveSettings();
    applySettings(false);
  }

  function toggleCompactMode() {
    setCompactMode(!isCompactMode());
  }

  function formatResetRemaining(value) {
    if (!value)
      return "";
    var reset = new Date(value);
    if (isNaN(reset.getTime()))
      return "";
    var minutes = Math.max(0, Math.ceil((reset.getTime() - Date.now()) / 60000));
    if (minutes < 60)
      return minutes + "m";

    var hours = Math.floor(minutes / 60);
    var remainderMinutes = minutes % 60;
    if (hours < 24) {
      if (hours < 10 && remainderMinutes > 0)
        return hours + "h" + remainderMinutes + "m";
      return hours + "h";
    }

    var days = Math.floor(hours / 24);
    var remainderHours = hours % 24;
    if (days < 10 && remainderHours > 0)
      return days + "d" + remainderHours + "h";
    return days + "d";
  }

  function formatResetRemainingCoarse(value) {
    if (!value)
      return "";
    var reset = new Date(value);
    if (isNaN(reset.getTime()))
      return "";
    var minutes = Math.max(0, Math.ceil((reset.getTime() - Date.now()) / 60000));
    if (minutes < 60)
      return minutes + "m";

    var hours = Math.floor(minutes / 60);
    if (hours < 24)
      return hours + "h";

    return Math.floor(hours / 24) + "d";
  }

  function barResetRemaining(value) {
    return useShortBarResetTime() ? formatResetRemainingCoarse(value) : formatResetRemaining(value);
  }

  function barWindowText(windowData, includeLabel) {
    var text = "";
    if (includeLabel)
      text += (windowData.label || windowData.id) + ":";
    if (displayPercent(windowData) >= 100)
      text += "full";
    else
      text += displayPercentText(windowData);
    var reset = barResetRemaining(windowData.resetAt);
    if (reset !== "")
      text += ":" + reset;
    return text;
  }

  function compactStateText(provider) {
    var state = providerStateText(provider);
    if (state === "Auth required")
      return "auth";
    if (state === "Timed out")
      return "timeout";
    if (state === "Rate limited")
      return "rate";
    if (state.indexOf("cooldown") !== -1 || state.indexOf("Cooldown") !== -1)
      return "cooldown";
    if (state === "Stale cache")
      return "stale";
    return state || "n/a";
  }

  function compactBarFor(provider, shortLabel) {
    if ((!provider || provider.available === false) && !anyBarWindowEnabled())
      return "";
    if (!provider || provider.available === false)
      return shortLabel + " " + compactStateText(provider);

    var label = shortLabel + (provider.stale ? "*" : "");
    if (provider.mode === "exact-remaining") {
      var rows = barQuotaWindows(provider);
      if (rows.length === 0)
        return "";
      var values = [];
      for (var i = 0; i < rows.length; i++)
        values.push(barWindowText(rows[i], false));
      var text = label + " " + values.join(" ");
      var state = compactStateText(provider);
      if (state !== "n/a" && state !== "Statusline cache" && state !== "Cached")
        text += " " + state;
      return text;
    }

    return label + " n/a";
  }

  function detailedBarFor(provider, shortLabel) {
    if ((!provider || provider.available === false) && !anyBarWindowEnabled())
      return "";
    if (!provider || provider.available === false) {
      var unavailableState = providerStateText(provider);
      return shortLabel + " " + (unavailableState || "n/a");
    }

    var label = shortLabel + (provider.stale ? "*" : "");
    if (provider.mode === "exact-remaining") {
      var rows = barQuotaWindows(provider);
      if (rows.length === 0)
        return "";
      var values = [];
      for (var i = 0; i < rows.length; i++)
        values.push(barWindowText(rows[i], true));
      var text = label + " " + values.join(" | ");
      var state = providerStateText(provider);
      if (state && state !== "Statusline cache")
        text += " " + state;
      return text;
    }

    return label + " n/a";
  }

  function barTextFor(provider, detailedLabel, compactLabel) {
    return isCompactMode() ? compactBarFor(provider, compactLabel) : detailedBarFor(provider, detailedLabel);
  }

  function appendBarPart(parts, text) {
    if (text && String(text).trim() !== "")
      parts.push(text);
  }

  function rebuildSummary() {
    var parts = [];
    if (pluginApi.pluginSettings.showUsedOnlyProvidersInBar !== false) {
      if (isProviderEnabled("codex"))
        appendBarPart(parts, barTextFor(providerById("codex"), "Codex", "Cx"));
      if (isProviderEnabled("opencode-go"))
        appendBarPart(parts, barTextFor(providerById("opencode-go"), "Go", "Go"));
    }
    if (isProviderEnabled("claude"))
      appendBarPart(parts, barTextFor(providerById("claude"), "Claude", "Cl"));
    summaryText = parts.length > 0 ? parts.join(isCompactMode() ? "·" : " · ") : (enabledProviderIds().length > 0 ? "AI Usage" : "AI Usage off");
  }

  function providerTooltipValue(provider) {
    if (!provider || provider.available === false) {
      var unavailableState = providerStateText(provider);
      var unavailableReason = provider && provider.staleReason ? provider.staleReason : "Unavailable";
      return unavailableState ? unavailableState + " | " + unavailableReason : unavailableReason;
    }

    var mode = provider.mode === "exact-remaining" ? representationTitle() + " quota" : "Unavailable";
    var state = providerStateText(provider);
    if (state)
      mode = state;
    if (provider.stale && !provider.failureKind)
      mode = "Stale";

    if (provider.mode === "exact-remaining") {
      var rows = quotaWindows(provider);
      if (rows.length === 0)
        return "No quota windows | " + mode;
      var parts = [];
      for (var i = 0; i < rows.length; i++) {
        var part = (rows[i].label || rows[i].id) + " " + displayPercentText(rows[i]) + " " + representationName();
        if (rows[i].resetAt)
          part += " reset " + formatTime(rows[i].resetAt);
        parts.push(part);
      }
      return parts.join(", ") + " | " + mode;
    }

    return mode;
  }

  function rebuildTooltipRows() {
    var rows = [];
    for (var i = 0; i < providers.length; i++)
      rows.push([providers[i].label || providers[i].id, providerTooltipValue(providers[i])]);

    if (rows.length === 0)
      rows.push(["AI Usage", enabledProviderIds().length === 0 ? "All providers disabled" : "No data yet"]);

    rows.push(["Updated", formatDateTime(lastUpdated)]);
    if (isStale)
      rows.push(["State", staleReason ? "Stale: " + staleReason : "Stale"]);
    else
      rows.push(["State", "Fresh"]);

    tooltipRows = rows;
  }
}
