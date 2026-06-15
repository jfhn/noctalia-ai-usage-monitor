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

  function loadSettings() {
    codexToggle.checked = providerEnabled("codex");
    opencodeGoToggle.checked = providerEnabled("opencode-go");
    claudeToggle.checked = providerEnabled("claude");
  }

  function saveSettings() {
    if (!pluginApi)
      return;

    var nextProviders = Object.assign({}, pluginApi.pluginSettings.providers || {}, {
      "codex": codexToggle.checked,
      "opencode-go": opencodeGoToggle.checked,
      "claude": claudeToggle.checked
    });

    pluginApi.pluginSettings = Object.assign({}, pluginApi.pluginSettings || {}, {
      "providers": nextProviders
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
}
