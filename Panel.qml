import QtQuick
import QtQuick.Layouts
import Quickshell
import qs.Commons
import qs.Services.UI
import qs.Widgets

Item {
  id: root

  required property var pluginApi

  readonly property var service: pluginApi ? pluginApi.mainInstance : null
  property real contentPreferredWidth: Math.round(440 * Style.uiScaleRatio)
  property real contentPreferredHeight: Math.min(760 * Style.uiScaleRatio, mainColumn.implicitHeight + Style.margin2L)
  property bool allowAttach: true

  function provider(id) {
    return service ? service.providerById(id) : null;
  }

  function statusText(providerData) {
    var state = providerStateText(providerData);
    if (!providerData || providerData.available === false)
      return state || "Unavailable";
    if (state)
      return state;
    if (providerData.stale)
      return "Stale";
    return providerData.mode === "exact-remaining" && service ? service.representationTitle() + " quota" : "Unavailable";
  }

  function stateColor(providerData, fallbackColor) {
    if (!providerData)
      return fallbackColor;
    if (providerData.failureKind || providerData.available === false)
      return Color.mError;
    if (providerData.stale)
      return Color.mError;
    return fallbackColor;
  }

  function quotaWindows(providerData) {
    if (!service || !providerData)
      return [];
    return service.quotaWindows(providerData);
  }

  function primaryWindow(providerData) {
    if (!service || !providerData)
      return null;
    return service.primaryWindow(providerData);
  }

  function providerStateText(providerData) {
    if (!service || !providerData)
      return "";
    return service.providerStateText(providerData);
  }

  function metricText(providerData) {
    if (!service || !providerData || providerData.available === false)
      return "n/a";
    if (providerData.mode === "exact-remaining") {
      var primary = primaryWindow(providerData);
      if (!primary)
        return "n/a";
      return (primary.label || primary.id) + " " + service.displayPercentText(primary) + " " + service.representationName();
    }
    return "n/a";
  }

  function subMetricText(providerData) {
    var state = providerStateText(providerData);
    if (!service || !providerData || providerData.available === false) {
      var reason = providerData && providerData.staleReason ? providerData.staleReason : "No local data";
      return state ? state + " | " + reason : reason;
    }
    if (providerData.mode === "exact-remaining") {
      var rows = quotaWindows(providerData);
      if (rows.length === 0)
        return "No quota windows";
      var parts = [];
      if (state && state !== "Statusline cache")
        parts.push(state);
      var primary = primaryWindow(providerData);
      if (primary)
        parts.push((primary.label || primary.id) + " reset " + (primary.resetAt ? service.formatTime(primary.resetAt) : "n/a"));
      for (var i = 0; i < rows.length; i++) {
        if (primary && rows[i].id === primary.id)
          continue;
        parts.push((rows[i].label || rows[i].id) + " " + service.displayPercentText(rows[i]));
      }
      return parts.join(" | ");
    }
    return "No quota data";
  }

  function windowDetailText(windowData, includeAlternate) {
    if (!service || !windowData)
      return "n/a";
    var parts = [padLeft(service.displayPercentText(windowData), 4) + " " + service.representationName()];
    var alternateText = service.alternatePercentText(windowData);
    if (includeAlternate !== false && alternateText !== "n/a")
      parts.push(padLeft(alternateText, 4) + " " + service.alternateRepresentationName());
    var reset = service.formatResetRemaining(windowData.resetAt);
    if (reset !== "")
      parts.push(padLeft(reset, 5));
    return parts.join(" | ");
  }

  function padLeft(value, width) {
    var text = String(value === null || value === undefined ? "" : value);
    while (text.length < width)
      text = " " + text;
    return text;
  }

  function headerRefreshText() {
    if (!service || !service.lastUpdated)
      return "Not refreshed yet";
    return "Updated " + service.formatTime(service.lastUpdated);
  }

  function panelLayoutStyle() {
    if (service)
      service.settingsVersion;
    if (!pluginApi || !pluginApi.pluginSettings)
      return "default";
    return pluginApi.pluginSettings.panelLayoutStyle || "default";
  }

  function isMeterRowsStyle() {
    return panelLayoutStyle() === "meterRows";
  }

  function isTilesStyle() {
    return panelLayoutStyle() === "tiles";
  }

  function providerAccentColor(id) {
    if (id === "codex")
      return "#74AA9C";
    if (id === "claude")
      return "#DE7356";
    if (id === "opencode-go")
      return Color.mOnSurfaceVariant;
    if (id === "cursor")
      return "#8AA4FF";
    return Color.mPrimary;
  }

  function providerCards() {
    var cards = [];
    if (!service)
      return cards;
    service.settingsVersion;
    service.refreshVersion;
    if (service.isProviderEnabled("codex")) {
      cards.push({
        id: "codex",
        color: providerAccentColor("codex")
      });
    }
    if (service.isProviderEnabled("opencode-go")) {
      cards.push({
        id: "opencode-go",
        color: providerAccentColor("opencode-go")
      });
    }
    if (service.isProviderEnabled("claude")) {
      cards.push({
        id: "claude",
        color: providerAccentColor("claude")
      });
    }
    if (service.isProviderEnabled("cursor")) {
      cards.push({
        id: "cursor",
        color: providerAccentColor("cursor")
      });
    }
    return cards;
  }

  function clampPercent(value) {
    if (value === null || value === undefined || isNaN(value))
      return 0;
    return Math.max(0, Math.min(100, value));
  }

  function windowDisplayPercent(windowData) {
    if (!service || !windowData)
      return 0;
    return clampPercent(service.displayPercent(windowData));
  }

  function resetClockText(windowData) {
    if (!service || !windowData || !windowData.resetAt)
      return "reset n/a";
    var reset = new Date(windowData.resetAt);
    if (isNaN(reset.getTime()))
      return "reset " + windowData.resetAt;
    var now = new Date();
    if (reset.getFullYear() === now.getFullYear()
        && reset.getMonth() === now.getMonth()
        && reset.getDate() === now.getDate())
      return "reset " + service.formatTime(windowData.resetAt);
    return "reset " + Qt.formatDateTime(reset, "MMM d HH:mm");
  }

  function windowLabelWidth(labelText) {
    return Math.max(Math.round(32 * Style.uiScaleRatio), Math.min(Math.round(112 * Style.uiScaleRatio), labelText.implicitWidth));
  }

  Flickable {
    id: flickable
    anchors.fill: parent
    clip: true
    contentWidth: width
    contentHeight: mainColumn.implicitHeight + Style.margin2L

    ColumnLayout {
      id: mainColumn
      x: Style.marginL
      y: Style.marginL
      width: Math.max(0, flickable.width - Style.margin2L)
      spacing: Style.marginM

      NBox {
        Layout.fillWidth: true
        implicitHeight: headerRow.implicitHeight + Style.margin2M

        RowLayout {
          id: headerRow
          anchors.fill: parent
          anchors.margins: Style.marginM
          spacing: Style.marginM

          NIcon {
            icon: "brain"
            pointSize: Style.fontSizeXXL
            color: Color.mPrimary
          }

          ColumnLayout {
            spacing: 0
            Layout.fillWidth: true

            NText {
              text: "AI Usage"
              pointSize: Style.fontSizeL
              font.weight: Style.fontWeightBold
              color: Color.mOnSurface
            }

            NText {
              text: root.headerRefreshText()
              pointSize: Style.fontSizeXS
              color: Color.mOnSurfaceVariant
              family: Settings.data.ui.fontFixed
            }
          }

          NIconButton {
            icon: service && service.isCompactMode() ? "arrows-maximize" : "arrows-minimize"
            tooltipText: service && service.isCompactMode() ? "Detailed bar" : "Compact bar"
            baseSize: Style.baseWidgetSize * 0.8
            enabled: service !== null
            onClicked: {
              if (service)
                service.toggleCompactMode();
            }
          }

          NIconButton {
            icon: "settings"
            tooltipText: "Settings"
            baseSize: Style.baseWidgetSize * 0.8
            onClicked: BarService.openPluginSettings(pluginApi.panelOpenScreen || Quickshell.screens[0], pluginApi.manifest)
          }

          NIconButton {
            icon: "arrows-exchange"
            tooltipText: service ? "Show " + service.nextRepresentationName() : "Toggle used/remaining"
            baseSize: Style.baseWidgetSize * 0.8
            enabled: service !== null
            onClicked: {
              if (service)
                service.flipRepresentation();
            }
          }

          NIconButton {
            icon: "refresh"
            tooltipText: "Refresh now"
            baseSize: Style.baseWidgetSize * 0.8
            enabled: service ? !service.collectorRunning : false
            onClicked: {
              if (service)
                service.refreshNow();
            }
          }

          NIconButton {
            icon: "close"
            tooltipText: "Close"
            baseSize: Style.baseWidgetSize * 0.8
            onClicked: pluginApi.closePanel(pluginApi.panelOpenScreen || Quickshell.screens[0])
          }
        }
      }

      Repeater {
        model: root.providerCards()

        delegate: NBox {
          id: card
          required property var modelData
          readonly property var providerData: root.provider(modelData.id)
          readonly property color accentColor: root.stateColor(providerData, modelData.color)
          readonly property var windows: root.quotaWindows(providerData)

          Layout.fillWidth: true
          implicitHeight: cardColumn.implicitHeight + Style.marginS + Style.radiusM * 0.5

          ColumnLayout {
            id: cardColumn
            anchors.fill: parent
            anchors.margins: Style.marginS
            anchors.bottomMargin: Style.radiusM * 0.5
            spacing: Style.marginS

            RowLayout {
              Layout.fillWidth: true
              spacing: Style.marginXS

              ColumnLayout {
                spacing: 0
                Layout.fillWidth: true
                visible: !root.isMeterRowsStyle() && !root.isTilesStyle()

                NText {
                  text: root.metricText(card.providerData)
                  pointSize: Style.fontSizeS
                  font.weight: Style.fontWeightSemiBold
                  color: card.accentColor
                  family: Settings.data.ui.fontFixed
                }
              }

              NText {
                text: card.providerData ? card.providerData.label : card.modelData.id
                pointSize: Style.fontSizeXS
                color: Color.mOnSurfaceVariant
                horizontalAlignment: root.isMeterRowsStyle() || root.isTilesStyle() ? Text.AlignLeft : Text.AlignRight
                Layout.fillWidth: root.isMeterRowsStyle() || root.isTilesStyle()
                Layout.alignment: Qt.AlignTop
              }
            }

            ColumnLayout {
              Layout.fillWidth: true
              spacing: Style.marginXS
              visible: card.windows.length > 0 && !root.isTilesStyle()

              Repeater {
                model: card.windows

                delegate: WindowRow {
                  required property var modelData
                  windowData: modelData
                  accentColor: card.accentColor
                  meterRows: root.isMeterRowsStyle()
                }
              }
            }

            GridLayout {
              Layout.fillWidth: true
              columns: 2
              columnSpacing: Style.marginXS
              rowSpacing: Style.marginXS
              visible: card.windows.length > 0 && root.isTilesStyle()

              Repeater {
                model: card.windows

                delegate: WindowTile {
                  required property var modelData
                  windowData: modelData
                  accentColor: card.accentColor
                }
              }
            }

            NText {
              text: root.subMetricText(card.providerData)
              pointSize: Style.fontSizeXS
              color: Color.mOnSurfaceVariant
              wrapMode: Text.WrapAtWordBoundaryOrAnywhere
              Layout.fillWidth: true
              visible: card.windows.length === 0
            }

            RowLayout {
              Layout.fillWidth: true

              NText {
                text: root.statusText(card.providerData)
                pointSize: Style.fontSizeXS
                color: root.stateColor(card.providerData, Color.mOnSurfaceVariant)
              }

              Item {
                Layout.fillWidth: true
              }

              NText {
                text: card.providerData ? card.providerData.source : ""
                pointSize: Style.fontSizeXS
                color: Color.mOnSurfaceVariant
                elide: Text.ElideLeft
                horizontalAlignment: Text.AlignRight
                Layout.maximumWidth: Math.round(root.contentPreferredWidth * 0.45)
              }
            }
          }
        }
      }
    }
  }

  component WindowRow: ColumnLayout {
    property var windowData
    property color accentColor: Color.mPrimary
    property bool meterRows: false

    Layout.fillWidth: true
    spacing: meterRows ? 0 : Style.marginXS

    RowLayout {
      visible: !meterRows
      Layout.fillWidth: true
      spacing: Style.marginS

      NText {
        id: windowRowLabel
        text: windowData ? (windowData.label || windowData.id) : ""
        pointSize: Style.fontSizeXS
        font.weight: Style.fontWeightSemiBold
        color: accentColor
        family: Settings.data.ui.fontFixed
        Layout.preferredWidth: root.windowLabelWidth(windowRowLabel)
      }

      NText {
        text: root.windowDetailText(windowData, true)
        pointSize: Style.fontSizeXS
        color: Color.mOnSurface
        family: Settings.data.ui.fontFixed
        elide: Text.ElideRight
        Layout.fillWidth: true
      }

      NText {
        text: root.resetClockText(windowData)
        pointSize: Style.fontSizeXS
        color: Color.mOnSurfaceVariant
        horizontalAlignment: Text.AlignRight
      }
    }

    Item {
      id: meterRowSlot

      readonly property real displayPercent: root.windowDisplayPercent(windowData)

      visible: meterRows
      Layout.fillWidth: true
      Layout.preferredHeight: Math.max(Math.round(34 * Style.uiScaleRatio), meterContent.implicitHeight + Style.marginS)

      Rectangle {
        id: meterTrack

        anchors.fill: parent
        radius: Style.radiusS
        color: accentColor
        opacity: 0.12
      }

      Rectangle {
        anchors.left: parent.left
        anchors.top: parent.top
        anchors.bottom: parent.bottom
        width: Math.round(parent.width * meterRowSlot.displayPercent / 100)
        radius: meterTrack.radius
        color: accentColor
        opacity: 0.32
        visible: width > 0

        Behavior on width {
          NumberAnimation {
            duration: 180
            easing.type: Easing.OutCubic
          }
        }
      }

      RowLayout {
        id: meterContent

        anchors.left: parent.left
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
        anchors.leftMargin: Style.marginS
        anchors.rightMargin: Style.marginS
        spacing: Style.marginS

        NText {
          id: meterRowLabel
          text: windowData ? (windowData.label || windowData.id) : ""
          pointSize: Style.fontSizeXS
          font.weight: Style.fontWeightSemiBold
          color: accentColor
          family: Settings.data.ui.fontFixed
          Layout.preferredWidth: root.windowLabelWidth(meterRowLabel)
        }

        NText {
          text: root.windowDetailText(windowData, false)
          pointSize: Style.fontSizeXS
          color: Color.mOnSurface
          family: Settings.data.ui.fontFixed
          elide: Text.ElideRight
          Layout.fillWidth: true
        }

        NText {
          text: root.resetClockText(windowData)
          pointSize: Style.fontSizeXS
          color: Color.mOnSurface
          horizontalAlignment: Text.AlignRight
        }
      }
    }

    Item {
      id: windowBarSlot

      readonly property real displayPercent: root.windowDisplayPercent(windowData)

      visible: !meterRows
      Layout.fillWidth: true
      Layout.preferredHeight: Math.max(6, Math.round(8 * Style.uiScaleRatio))

      Rectangle {
        id: windowBarTrack

        anchors.fill: parent
        radius: Math.round(height / 2)
        color: accentColor
        opacity: 0.16
      }

      Rectangle {
        anchors.left: windowBarTrack.left
        anchors.verticalCenter: windowBarTrack.verticalCenter
        width: Math.round(windowBarTrack.width * windowBarSlot.displayPercent / 100)
        height: windowBarTrack.height
        radius: windowBarTrack.radius
        color: accentColor
        visible: width > 0

        Behavior on width {
          NumberAnimation {
            duration: 180
            easing.type: Easing.OutCubic
          }
        }
      }
    }
  }

  component WindowTile: Item {
    property var windowData
    property color accentColor: Color.mPrimary

    readonly property string resetLeft: root.service ? root.service.formatResetRemaining(windowData && windowData.resetAt) : ""

    Layout.fillWidth: true
    Layout.preferredHeight: Math.max(Math.round(58 * Style.uiScaleRatio), tileContent.implicitHeight + Style.marginM)

    Rectangle {
      anchors.fill: parent
      radius: Style.radiusS
      color: accentColor
      opacity: 0.14
      border.color: accentColor
      border.width: Style.borderS
    }

    Rectangle {
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.bottom: parent.bottom
      height: Math.max(2, Math.round(3 * Style.uiScaleRatio))
      radius: Math.round(height / 2)
      color: accentColor
      opacity: 0.85
    }

    ColumnLayout {
      id: tileContent

      anchors.fill: parent
      anchors.margins: Style.marginS
      spacing: 0

      RowLayout {
        Layout.fillWidth: true
        spacing: Style.marginXS

        NText {
          text: windowData ? (windowData.label || windowData.id) : ""
          pointSize: Style.fontSizeXS
          font.weight: Style.fontWeightSemiBold
          color: accentColor
          family: Settings.data.ui.fontFixed
        }

        Item {
          Layout.fillWidth: true
        }

        NText {
          text: windowData && root.service ? root.service.displayPercentText(windowData) : "n/a"
          pointSize: Style.fontSizeS
          font.weight: Style.fontWeightSemiBold
          color: Color.mOnSurface
          family: Settings.data.ui.fontFixed
          horizontalAlignment: Text.AlignRight
        }
      }

      RowLayout {
        Layout.fillWidth: true
        spacing: Style.marginXS

        NText {
          text: root.service ? root.service.representationName() : ""
          pointSize: Style.fontSizeXXS
          color: Color.mOnSurfaceVariant
          elide: Text.ElideRight
          Layout.fillWidth: true
        }

        NText {
          text: resetLeft || "reset n/a"
          pointSize: Style.fontSizeXXS
          color: Color.mOnSurfaceVariant
          family: Settings.data.ui.fontFixed
          horizontalAlignment: Text.AlignRight
        }
      }
    }
  }
}
