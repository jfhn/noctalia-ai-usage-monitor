import QtQuick
import QtQuick.Layouts
import qs.Commons
import qs.Services.UI
import qs.Widgets

ColumnLayout {
  id: root

  property var pluginApi: null
  property real preferredWidth: 560 * Style.uiScaleRatio

  spacing: Style.marginM

  Component.onCompleted: loadSettings()

  function providerSettings() {
    if (!pluginApi || !pluginApi.pluginSettings || !pluginApi.pluginSettings.providers)
      return {};
    return pluginApi.pluginSettings.providers;
  }

  function providerEnabled(id) {
    var providers = providerSettings();
    return providers[id] !== false;
  }

  function barWindowSettings() {
    if (!pluginApi || !pluginApi.pluginSettings || !pluginApi.pluginSettings.barWindows)
      return {};
    return pluginApi.pluginSettings.barWindows;
  }

  function barWindowEnabled(id) {
    var windows = barWindowSettings();
    return windows[id] !== false;
  }

  function panelLayoutStyle() {
    if (!pluginApi || !pluginApi.pluginSettings)
      return "default";
    return pluginApi.pluginSettings.panelLayoutStyle || "default";
  }

  function shortBarResetTime() {
    return pluginApi && pluginApi.pluginSettings && pluginApi.pluginSettings.shortBarResetTime === true;
  }

  function loadSettings() {
    codexToggle.checked = providerEnabled("codex");
    opencodeGoToggle.checked = providerEnabled("opencode-go");
    claudeToggle.checked = providerEnabled("claude");
    cursorToggle.checked = providerEnabled("cursor");
    fiveHourToggle.checked = barWindowEnabled("five_hour");
    weeklyToggle.checked = barWindowEnabled("weekly");
    monthlyToggle.checked = barWindowEnabled("monthly");
    shortBarResetToggle.checked = shortBarResetTime();
    panelLayoutCombo.currentKey = panelLayoutStyle();
  }

  function saveSettings() {
    if (!pluginApi)
      return;

    var nextProviders = Object.assign({}, pluginApi.pluginSettings.providers || {}, {
      "codex": codexToggle.checked,
      "opencode-go": opencodeGoToggle.checked,
      "claude": claudeToggle.checked,
      "cursor": cursorToggle.checked
    });
    var nextBarWindows = Object.assign({}, pluginApi.pluginSettings.barWindows || {}, {
      "five_hour": fiveHourToggle.checked,
      "weekly": weeklyToggle.checked,
      "monthly": monthlyToggle.checked
    });

    pluginApi.pluginSettings = Object.assign({}, pluginApi.pluginSettings || {}, {
      "providers": nextProviders,
      "barWindows": nextBarWindows,
      "shortBarResetTime": shortBarResetToggle.checked,
      "panelLayoutStyle": panelLayoutCombo.currentKey || "default"
    });
    pluginApi.saveSettings();
    pluginApi.mainInstance?.reloadSettings();
    ToastService.showNotice("AI Usage Monitor", "Settings saved.", "settings");
  }

  NLabel {
    Layout.fillWidth: true
    label: "Providers"
    description: "Disabled providers are hidden and skipped during refresh."
    icon: "brain"
    iconColor: Color.mPrimary
  }

  NToggle {
    id: codexToggle
    Layout.fillWidth: true
    label: "Codex"
    description: "Read Codex quota windows from local session data."
    checked: true
    onToggled: checked => codexToggle.checked = checked
  }

  NToggle {
    id: opencodeGoToggle
    Layout.fillWidth: true
    label: "OpenCode Go"
    description: "Query OpenCode Go quota data when local auth is configured."
    checked: true
    onToggled: checked => opencodeGoToggle.checked = checked
  }

  NToggle {
    id: claudeToggle
    Layout.fillWidth: true
    label: "Claude Code"
    description: "Read Claude Code quota data from statusline cache or OAuth usage."
    checked: true
    onToggled: checked => claudeToggle.checked = checked
  }

  NToggle {
    id: cursorToggle
    Layout.fillWidth: true
    label: "Cursor"
    description: "Read Cursor billing-cycle usage from local Cursor auth and Cursor usage endpoints."
    checked: true
    onToggled: checked => cursorToggle.checked = checked
  }

  NLabel {
    Layout.fillWidth: true
    label: "Panel"
    description: "Choose how quota windows are rendered in the expanded plugin menu."
    icon: "layout-list"
    iconColor: Color.mPrimary
  }

  NComboBox {
    id: panelLayoutCombo
    Layout.fillWidth: true
    label: "Window layout"
    description: "Default keeps separate text and bars; meter rows and tiles provide denser visual summaries."
    model: [
      {
        "key": "default",
        "name": "Default"
      },
      {
        "key": "meterRows",
        "name": "Meter rows"
      },
      {
        "key": "tiles",
        "name": "Tiles"
      }
    ]
    currentKey: "default"
    defaultValue: "default"
    onSelected: key => panelLayoutCombo.currentKey = key
  }

  NLabel {
    Layout.fillWidth: true
    label: "Status Bar"
    description: "Choose which quota windows appear in the compact and detailed bar text."
    icon: "panel-top"
    iconColor: Color.mPrimary
  }

  NToggle {
    id: fiveHourToggle
    Layout.fillWidth: true
    label: "5-hour window"
    description: "Show 5h quota percentages and remaining reset time in the bar."
    checked: true
    onToggled: checked => fiveHourToggle.checked = checked
  }

  NToggle {
    id: weeklyToggle
    Layout.fillWidth: true
    label: "7-day window"
    description: "Show 7d quota percentages and remaining reset time in the bar."
    checked: true
    onToggled: checked => weeklyToggle.checked = checked
  }

  NToggle {
    id: monthlyToggle
    Layout.fillWidth: true
    label: "30-day window"
    description: "Show 30d quota percentages and remaining reset time when a provider reports them."
    checked: true
    onToggled: checked => monthlyToggle.checked = checked
  }

  NToggle {
    id: shortBarResetToggle
    Layout.fillWidth: true
    label: "Short reset times"
    description: "Show coarse reset-left values in the bar, such as 3h or 2d instead of 3h23m or 2d3h."
    checked: false
    onToggled: checked => shortBarResetToggle.checked = checked
  }
}
