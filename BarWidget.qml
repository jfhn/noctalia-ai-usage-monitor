import QtQuick
import QtQuick.Layouts
import Quickshell
import qs.Commons
import qs.Services.UI
import qs.Widgets

Item {
  id: root

  required property var pluginApi
  property ShellScreen screen
  property string widgetId: ""
  property string section: ""
  property int sectionWidgetIndex: -1
  property int sectionWidgetsCount: 0

  readonly property var service: pluginApi ? pluginApi.mainInstance : null
  readonly property string screenName: screen ? screen.name : ""
  readonly property string barPosition: Settings.getBarPositionForScreen(screenName)
  readonly property bool isVertical: barPosition === "left" || barPosition === "right"
  readonly property real capsuleHeight: Style.getCapsuleHeightForScreen(screenName)
  readonly property real barFontSize: Style.getBarFontSizeForScreen(screenName)
  readonly property real iconSize: Style.toOdd(capsuleHeight * 0.48)
  readonly property string textValue: service ? service.summaryText : "Codex n/a Go n/a Claude n/a"
  readonly property real contentWidth: isVertical ? capsuleHeight : Math.round(contentRow.implicitWidth + Style.margin2M)
  readonly property real contentHeight: isVertical ? Math.round(contentRow.implicitHeight + Style.margin2M) : capsuleHeight

  implicitWidth: contentWidth
  implicitHeight: contentHeight

  NPopupContextMenu {
    id: contextMenu
    model: [
      {
        "label": "Refresh now",
        "action": "refresh",
        "icon": "refresh"
      }
    ]

    onTriggered: action => {
      contextMenu.close();
      PanelService.closeContextMenu(screen);
      if (action === "refresh" && root.service)
        root.service.refreshNow();
    }
  }

  Rectangle {
    id: visualCapsule
    width: root.contentWidth
    height: root.contentHeight
    anchors.centerIn: parent
    radius: Style.radiusM
    color: Style.capsuleColor
    border.color: Style.capsuleBorderColor
    border.width: Style.capsuleBorderWidth

    RowLayout {
      id: contentRow
      anchors.centerIn: parent
      spacing: Style.marginS

      NIcon {
        icon: "brain"
        pointSize: root.iconSize
        applyUiScale: false
        color: root.service && root.service.isStale ? Color.mTertiary : Color.mPrimary
        Layout.alignment: Qt.AlignVCenter
      }

      NText {
        text: root.textValue
        pointSize: root.barFontSize
        applyUiScale: false
        family: Settings.data.ui.fontFixed
        color: root.service && root.service.isStale ? Color.mTertiary : Color.mOnSurface
        verticalAlignment: Text.AlignVCenter
        Layout.alignment: Qt.AlignVCenter
        visible: !root.isVertical
      }
    }
  }

  MouseArea {
    id: mouseArea
    anchors.fill: parent
    cursorShape: Qt.PointingHandCursor
    acceptedButtons: Qt.LeftButton | Qt.RightButton
    hoverEnabled: true

    onClicked: mouse => {
      TooltipService.hide();
      if (mouse.button === Qt.LeftButton && pluginApi) {
        pluginApi.togglePanel(screen, root);
      } else if (mouse.button === Qt.RightButton) {
        PanelService.showContextMenu(contextMenu, root, screen);
      }
    }

    onEntered: {
      if (root.service)
        TooltipService.show(root, root.service.tooltipRows, BarService.getTooltipDirection(root.screenName));
      tooltipRefreshTimer.start();
    }

    onExited: {
      tooltipRefreshTimer.stop();
      TooltipService.hide(root);
    }
  }

  Timer {
    id: tooltipRefreshTimer
    interval: 1000
    repeat: true
    onTriggered: {
      if (mouseArea.containsMouse && root.service)
        TooltipService.updateText(root.service.tooltipRows);
    }
  }
}
