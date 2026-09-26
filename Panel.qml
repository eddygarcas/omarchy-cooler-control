import QtQuick
import QtQuick.Layouts
import QtQuick.Shapes
import qs.Commons
import qs.Ui
import "Model.js" as Model

Panel {
  id: root
  moduleName: "eduard.cooler-control"
  ipcTarget: moduleName

  readonly property var svc: bar && bar.shell ? bar.shell.serviceFor(root.moduleName) : null
  readonly property var zones: svc ? svc.fanZones : []
  // A pwm header with nothing plugged into it still shows up in sysfs — this
  // is the subset Service has actually seen spin (see Model.nextUnpluggedState).
  // It drives the bar icon's "fastest fan" readout and the no-fan hint below,
  // but *not* which zones are listed: a header with 0 RPM is dimmed in the
  // selector rather than removed, because "no RPM" also describes a
  // perfectly real fan with no tachometer wire (2/3-pin on a 4-pin header),
  // and Identify -- the one action that drives a fan hard enough to judge it
  // -- used to make exactly such a fan vanish from the list mid-click.
  readonly property var connectedZones: root.zones.filter(function(z) { return !z.unplugged })
  // Stricter subset for the expanded cards: a fan only gets a card once it
  // has actually reported RPM inside the sparkline window. `unplugged` alone
  // is not enough -- it only fires after a header has been driven at a real
  // duty and stayed silent, so a header idling at 0% / 0 RPM (nothing
  // plugged in, or a fan the board has stopped) would otherwise still get a
  // card with nothing to chart. It reappears the moment it spins.
  // One rule for "is there a fan talking back on this header?", shared by
  // the compact selector's dimming, the name caption, the hero hint, and
  // the expanded cards: RPM reported at some point in the sparkline window.
  function isReporting(zone) {
    if (!zone || zone.unplugged) return false
    var h = zone.rpmHistory || []
    for (var i = 0; i < h.length; i++) if (h[i] > 0) return true
    return zone.rpm > 0
  }
  readonly property var reportingZones: root.zones.filter(root.isReporting)
  readonly property bool available: svc ? svc.available : false
  readonly property bool detecting: svc ? svc.detecting : false
  readonly property string detectError: svc ? svc.detectError : ""
  readonly property real cpuTemperature: svc ? svc.cpuTemperature : -1
  readonly property var tempHistory: svc ? svc.tempHistory : []
  readonly property string selectedZoneKey: svc ? svc.selectedZoneKey : ""
  readonly property var selectedZone: {
    var pool = root.zones
    if (pool.length === 0) return null
    for (var i = 0; i < pool.length; i++)
      if (pool[i].key === root.selectedZoneKey) return pool[i]
    return pool[0]
  }
  readonly property bool customMode: !!(root.selectedZone && root.selectedZone.mode === "custom")
  readonly property bool identifyBusy: svc ? svc.identifyBusy : false

  // What the bar shows: the spinning fan glyph (default), CPU temperature,
  // or the selected fan's duty cycle. Persisted per-widget in shell.json —
  // same mechanism Omarchy's own btop plugin uses for its icon style.
  readonly property string iconMode: String(setting("iconMode", "spin"))

  function persistPluginSetting(name, value) {
    if (!bar || !bar.shell || typeof bar.shell.updateEntryInline !== "function") return
    var entry = { id: moduleName }
    for (var key in settings) if (key !== "id") entry[key] = settings[key]
    entry[name] = value
    settings = entry
    bar.shell.updateEntryInline(moduleName, entry)
  }

  function setIconMode(mode) {
    if (["spin", "temp", "speed"].indexOf(mode) < 0 || mode === root.iconMode) return
    persistPluginSetting("iconMode", mode)
  }

  // Composes onto "CPU <temp>" — every branch is either empty or already
  // starts with its own " · " separator.
  readonly property string statusSuffix: !root.available
    ? " · no fan controller detected"
    : root.topZone
      ? " · " + Model.formatRpm(root.topZone.rpm)
      : (root.zones.length > 0 ? " · no fan reporting" : "")

  // Fastest connected fan, for the bar icon's glance-value and spin speed —
  // the bar has room for one number, not a per-zone breakdown.
  readonly property var topZone: {
    var best = null
    for (var i = 0; i < root.connectedZones.length; i++) {
      var z = root.connectedZones[i]
      if (z.rpm > 0 && (!best || z.rpm > best.rpm)) best = z
    }
    return best
  }

  readonly property string barTooltipText: "Cooler control — CPU " + Model.formatTemp(root.cpuTemperature) + root.statusSuffix

  // Expanded view: one card per fan (live readout, sparkline, and — for a
  // zone on a custom curve — the curve itself with its thresholds), instead
  // of the compact single-zone selector. Persisted next to iconMode.
  readonly property bool expanded: setting("expanded", false) === true

  function setExpanded(on) {
    if (!!on === root.expanded) return
    persistPluginSetting("expanded", !!on)
  }

  // Every poll (every 2s) rebuilds the zone objects, and a Repeater over a
  // JS array tears down and recreates every delegate whenever that array is
  // reassigned -- which would reset each card's name field mid-edit and
  // restart its spin animation. So the cards repeat over the list of zone
  // *keys* instead, which only changes when the set of fans actually
  // reporting data changes, and each card looks its live zone up by key.
  // Only zones reporting RPM get a card (see reportingZones): a header with
  // no reading stays in the compact selector, dimmed, where it can still be
  // identified or renamed, but has nothing to chart.
  property var zoneKeys: []

  function refreshZoneKeys() {
    var keys = root.reportingZones.map(function(z) { return z.key })
    if (keys.join("\u0001") !== root.zoneKeys.join("\u0001")) root.zoneKeys = keys
  }

  onZonesChanged: refreshZoneKeys()
  Component.onCompleted: refreshZoneKeys()

  // Hardware truth vs. the switch. Empty when the header is doing what the
  // mode says; otherwise a one-line reason, shown in urgent colour next to
  // a button that redoes the write (svc.retryZone).
  function zoneWarning(zone) {
    if (!zone || !zone.enablePath) return ""
    if (zone.lastWriteFailed) return "Last write to the fan controller failed — authentication cancelled?"
    if (Model.boardNotInControl(zone)) return "Header is in manual mode — the board is not driving this fan"
    if (zone.mode === "custom" && zone.hwEnable !== "" && !Model.isManualEnable(zone.hwEnable))
      return "The board took this fan back — the custom curve is not in charge"
    return ""
  }
  function zoneRetryLabel(zone) {
    return zone && zone.mode === "custom" ? "Reapply curve" : "Hand back to board"
  }

  // One entry point for every way of moving a threshold: compact sliders,
  // card steppers, and dragging a breakpoint on either curve chart.
  function commitThreshold(key, which, temp) {
    if (!root.svc) return
    if (which === "quiet") root.svc.setQuiet(key, temp)
    else if (which === "ramp") root.svc.setRamp(key, temp)
    else if (which === "full") root.svc.setFull(key, temp)
  }

  function zoneByKey(key) {
    var pool = root.zones
    for (var i = 0; i < pool.length; i++)
      if (pool[i].key === key) return pool[i]
    return null
  }

  // What a card renders in the moment between a rescan dropping a zone and
  // the key list catching up, so no binding has to null-check every field.
  readonly property var placeholderZone: ({
    key: "", label: "", autoLabel: "", customLabel: "", fanPath: "",
    rpm: -1, duty: -1, unplugged: false, identifying: false, mode: "auto",
    quietC: 45, rampC: 65, fullC: 80, rpmHistory: [], dutyHistory: [],
    enablePath: "", hwEnable: "", lastWriteFailed: false, pendingApply: false
  })

  // Up to three cards per row at a comfortable width; on a screen too narrow
  // for that the popup is capped (fittedContentWidth) and the cards shrink
  // to share whatever width is left rather than wrapping unevenly.
  readonly property int preferredCardWidth: Style.space(236)
  readonly property int cardGap: Style.space(12)
  readonly property int cardColumns: Math.max(1, Math.min(3, root.reportingZones.length))
  readonly property int cardRadius: Style.space(12)
  // Never narrower than the compact popup: one lone card would otherwise
  // squeeze the hero and the bar-icon row into a strip.
  readonly property int expandedWidth: Math.max(Style.space(380),
    cardColumns * preferredCardWidth + (cardColumns - 1) * cardGap
    + panel.padding * 2 + Border.left(panel.borderSpec) + Border.right(panel.borderSpec))
  readonly property int cardWidth: Math.floor((column.width - (cardColumns - 1) * cardGap) / cardColumns)

  visible: true
  implicitWidth: buttonLoader.item ? buttonLoader.item.implicitWidth : 0
  implicitHeight: buttonLoader.item ? buttonLoader.item.implicitHeight : 0

  // The icon-slot pinwheel (fixed square, like every other bar icon) and the
  // two text readouts (content-width, like the clock or a percentage
  // widget) have fundamentally different sizing — a Loader swaps the whole
  // component rather than trying to force one shape into the other's box.
  Loader {
    id: buttonLoader
    anchors.fill: parent
    sourceComponent: root.iconMode === "spin" ? spinButtonComponent : valueButtonComponent
  }

  Component {
    id: spinButtonComponent
    BarIconButton {
      bar: root.bar
      slotSize: Style.bar.iconSlot
      tooltipText: root.barTooltipText
      iconComponent: Component {
        Item {
          FanIcon {
            anchors.centerIn: parent
            iconSize: Style.bar.iconCanvas * 0.78
            tint: root.bar.foreground
            dutyPercent: root.topZone ? root.topZone.duty : 0
          }
        }
      }
      onPressed: function(b) { root.toggle() }
    }
  }

  Component {
    id: valueButtonComponent
    WidgetButton {
      bar: root.bar
      labelVisible: false
      hasVisualContent: true
      fixedWidth: contentRow.implicitWidth + Style.space(16)
      tooltipText: root.barTooltipText
      onPressed: function(b) { root.toggle() }

      Row {
        id: contentRow
        anchors.centerIn: parent
        spacing: Style.space(4)

        TemperatureIcon {
          visible: root.iconMode === "temp"
          anchors.verticalCenter: parent.verticalCenter
          iconSize: Style.bar.iconCanvas * 0.8
          tint: root.bar.foreground
        }

        FanIcon {
          visible: root.iconMode === "speed"
          anchors.verticalCenter: parent.verticalCenter
          iconSize: Style.bar.iconCanvas * 0.8
          tint: root.bar.foreground
          dutyPercent: 0 // static — this readout isn't a live spin gauge
        }

        Text {
          textFormat: Text.PlainText
          anchors.verticalCenter: parent.verticalCenter
          text: root.iconMode === "temp"
            ? (root.cpuTemperature > 0 ? Math.round(root.cpuTemperature) + "°" : "--°")
            : Model.formatDuty(root.selectedZone ? root.selectedZone.duty : -1)
          color: root.bar.foreground
          font.family: root.bar.fontFamily
          font.pixelSize: Style.bar.iconFont
          font.bold: true
        }
      }
    }
  }

  KeyboardPanel {
    id: panel
    anchorItem: buttonLoader
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(root.expanded ? root.expandedWidth : Style.space(380))
    contentHeight: panel.fittedContentHeight(column.implicitHeight)

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }

      // fittedContentHeight caps the card at the screen; several rows of fan
      // cards can exceed that, so the content scrolls instead of clipping.
      Flickable {
        id: scroller
        anchors.fill: parent
        contentWidth: width
        contentHeight: column.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        interactive: contentHeight > height

      Column {
        id: column
        width: scroller.width
        spacing: Style.space(14)

        // ---------- Hero ----------
        PanelHero {
          width: parent.width
          title: "Cooler Control"
          meta: "CPU " + Model.formatTemp(root.cpuTemperature) + root.statusSuffix
          detail: root.expanded
            ? (root.reportingZones.length > 0 ? root.reportingZones.length + (root.reportingZones.length === 1 ? " FAN" : " FANS") : "")
            : (root.selectedZone ? (root.customMode ? "CUSTOM CURVE" : "AUTO") : "")
          foreground: root.bar.foreground
          fontFamily: root.bar.fontFamily
          iconComponent: Component {
            FanIcon {
              iconSize: Style.font.display
              tint: root.bar.foreground
              dutyPercent: root.topZone ? root.topZone.duty : 0
            }
          }
          trailingControl: Component {
            Button {
              text: root.expanded ? "Collapse" : "Expand"
              tooltipText: root.expanded
                ? "Back to the compact single-fan view"
                : "One card per fan: live readout, speed graph, and curve thresholds"
              fontSize: Style.font.bodySmall
              foreground: root.bar.foreground
              fontFamily: root.bar.fontFamily
              bordered: true
              radius: height / 2
              visible: root.zones.length > 0
              onClicked: root.setExpanded(!root.expanded)
            }
          }
        }

        PanelSeparator { foreground: root.bar.foreground }

        // ---------- Bar icon ----------
        Column {
          width: parent.width
          spacing: Style.space(8)

          PanelSectionHeader {
            text: "BAR ICON"
            foreground: root.bar.foreground
            fontFamily: root.bar.fontFamily
          }

          Row {
            width: parent.width
            spacing: Style.space(8)

            Button {
              text: "Spin"
              tooltipText: "Animated fan icon"
              selected: root.iconMode === "spin"
              fontSize: Style.font.bodySmall
              foreground: root.bar.foreground
              fontFamily: root.bar.fontFamily
              bordered: true
              radius: height / 2
              onClicked: root.setIconMode("spin")
            }

            Button {
              text: "Temperature"
              tooltipText: "CPU temperature"
              selected: root.iconMode === "temp"
              fontSize: Style.font.bodySmall
              foreground: root.bar.foreground
              fontFamily: root.bar.fontFamily
              bordered: true
              radius: height / 2
              onClicked: root.setIconMode("temp")
            }

            Button {
              text: "Fan Speed"
              tooltipText: "Selected fan's duty cycle"
              selected: root.iconMode === "speed"
              fontSize: Style.font.bodySmall
              foreground: root.bar.foreground
              fontFamily: root.bar.fontFamily
              bordered: true
              radius: height / 2
              onClicked: root.setIconMode("speed")
            }
          }
        }

        PanelSeparator { foreground: root.bar.foreground }

        // ---------- No controller found / nothing connected ----------
        Column {
          width: parent.width
          spacing: Style.space(8)
          visible: !root.available || root.reportingZones.length === 0

          Text {
            textFormat: Text.PlainText
            width: parent.width
            text: !root.available
              ? "No pwm-capable fan controller was found under /sys/class/hwmon. "
                + "Most desktop boards expose one once lm_sensors probes and loads "
                + "the right Super I/O driver (nct6775, it87, ...)."
              : "Found " + root.zones.length + " fan header" + (root.zones.length === 1 ? "" : "s")
                + ", but none has reported an RPM signal yet. That usually means "
                + "nothing is plugged in — or the fan has no tachometer wire. Every "
                + "header stays listed below either way; use Identify to check by ear."
            color: Qt.darker(root.bar.foreground, 1.4)
            font.family: root.bar.fontFamily
            font.pixelSize: Style.font.caption
            wrapMode: Text.WordWrap
          }

          Text {
            textFormat: Text.PlainText
            width: parent.width
            visible: root.detectError !== ""
            text: root.detectError
            color: Color.urgent
            font.family: root.bar.fontFamily
            font.pixelSize: Style.font.caption
            wrapMode: Text.WordWrap
          }

          Button {
            visible: !root.available
            text: root.detecting ? "Detecting…" : "Detect Fan Controller"
            tooltipText: "Runs sensors-detect --auto via pkexec, then rescans"
            fontSize: Style.font.bodySmall
            foreground: root.bar.foreground
            fontFamily: root.bar.fontFamily
            bordered: true
            radius: height / 2
            enabled: !root.detecting
            onClicked: { if (root.svc) root.svc.detectFanController() }
          }
        }

        // ---------- Zone selector ----------
        // Every header the board exposes, always. One that has not reported
        // any RPM (see isReporting -- it may be empty, or a fan with no
        // tachometer) is dimmed but stays selectable so it can still be
        // identified, renamed, or driven. Same rule as the expanded cards.
        Flow {
          width: parent.width
          spacing: Style.space(8)
          visible: !root.expanded && root.zones.length > 1

          Repeater {
            model: root.zones
            Button {
              required property var modelData
              text: modelData.label
              opacity: root.isReporting(modelData) ? 1 : 0.5
              tooltipText: root.isReporting(modelData)
                ? ""
                : "No RPM reading — nothing plugged in, or a fan without a tachometer wire"
              selected: modelData.key === root.selectedZoneKey
              fontSize: Style.font.bodySmall
              foreground: root.bar.foreground
              fontFamily: root.bar.fontFamily
              bordered: true
              radius: height / 2
              onClicked: { if (root.svc) root.svc.selectZone(modelData.key) }
            }
          }
        }

        // ---------- Rename + identify ----------
        Column {
          width: parent.width
          spacing: Style.space(6)
          visible: !root.expanded && root.selectedZone !== null

          PanelSectionHeader {
            text: "FAN NAME"
            foreground: root.bar.foreground
            fontFamily: root.bar.fontFamily
          }

          RowLayout {
            width: parent.width
            spacing: Style.space(8)

            TextField {
              id: labelField
              Layout.fillWidth: true
              placeholderText: root.selectedZone ? root.selectedZone.autoLabel : ""
              foreground: root.bar.foreground
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.bodySmall
              verticalPadding: Style.space(4)

              // `text` is deliberately not bound to the zone's label. Every
              // poll (Service.applyReadResults, every 2s) rebuilds the zone
              // objects, so a plain binding would re-evaluate on each tick
              // and overwrite whatever the user is mid-way through typing.
              // Instead the saved label is tracked here and only pushed
              // into the field while it isn't focused -- or whenever the
              // selected zone itself changes, since that's a different
              // fan's name and the old draft no longer applies.
              readonly property string savedLabel: root.selectedZone ? root.selectedZone.customLabel : ""
              readonly property string zoneKey: root.selectedZone ? root.selectedZone.key : ""

              Component.onCompleted: text = savedLabel
              onSavedLabelChanged: if (!activeFocus) text = savedLabel
              onZoneKeyChanged: text = savedLabel
              onEditingFinished: {
                if (root.svc && root.selectedZone) root.svc.setLabel(root.selectedZone.key, text)
                // Service trims the label; reflect that back even while the
                // field still has focus (Enter commits without blurring).
                text = savedLabel
              }
            }

            Button {
              text: root.selectedZone && root.selectedZone.identifying ? "Identifying…" : "Identify"
              tooltipText: "Ramps this fan to 100% for a few seconds so you can tell which one it is by ear or by eye"
              fontSize: Style.font.bodySmall
              foreground: root.bar.foreground
              fontFamily: root.bar.fontFamily
              bordered: true
              radius: height / 2
              enabled: root.selectedZone !== null && !root.identifyBusy
              onClicked: { if (root.svc && root.selectedZone) root.svc.identifyZone(root.selectedZone.key) }
            }
          }

          Text {
            textFormat: Text.PlainText
            width: parent.width
            text: root.selectedZone
              ? root.selectedZone.key + (root.selectedZone.fanPath === "" ? " · no tachometer input"
                : root.isReporting(root.selectedZone) ? " · reporting RPM"
                : " · no RPM reading (unplugged, or no tachometer wire)")
              : ""
            color: Qt.darker(root.bar.foreground, 1.6)
            font.family: root.bar.fontFamily
            font.pixelSize: Style.font.caption
            wrapMode: Text.WordWrap
          }
        }

        // ---------- Graph + gauge ----------
        RowLayout {
          width: parent.width
          spacing: Style.space(14)
          visible: root.available || root.cpuTemperature > 0

          HistoryGraph {
            Layout.fillWidth: true
            Layout.preferredHeight: root.expanded ? Style.space(110) : Style.space(96)
            history: root.tempHistory
            minValue: 20
            maxValue: 100
            lineColor: Color.accent
            foreground: root.bar.foreground
            currentLabel: Model.formatTemp(root.cpuTemperature)
            scaleLabel: root.expanded ? "CPU · LAST 3 MIN" : ""
          }

          FanGauge {
            visible: !root.expanded && root.selectedZone !== null
            Layout.preferredWidth: Style.space(96)
            Layout.preferredHeight: Style.space(96)
            value: root.selectedZone ? root.selectedZone.duty : 0
            caption: root.selectedZone ? Model.formatRpm(root.selectedZone.rpm) : ""
            trackColor: Style.selectedFillFor(root.bar.foreground, Color.accent)
            accentColor: Color.accent
            foreground: root.bar.foreground
          }
        }

        PanelSeparator { foreground: root.bar.foreground; visible: root.selectedZone !== null }

        // ---------- Mode + curve (compact) ----------
        Column {
          width: parent.width
          spacing: Style.space(14)
          visible: !root.expanded && root.selectedZone !== null

          Toggle {
            width: parent.width
            label: "Custom fan curve for " + (root.selectedZone ? root.selectedZone.label : "")
            description: root.customMode
              ? "This plugin drives the duty cycle from the sliders below."
              : "Off — the board's own fan curve is in charge."
            checked: root.customMode
            rounded: true
            foreground: root.bar.foreground
            fontFamily: root.bar.fontFamily
            onClicked: {
              if (root.svc && root.selectedZone)
                root.svc.setMode(root.selectedZone.key, root.customMode ? "auto" : "custom")
            }
          }

          // Shown only when sysfs disagrees with the switch above.
          RowLayout {
            width: parent.width
            spacing: Style.space(8)
            visible: root.zoneWarning(root.selectedZone) !== ""

            Text {
              textFormat: Text.PlainText
              Layout.fillWidth: true
              text: root.zoneWarning(root.selectedZone)
              color: Color.urgent
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.caption
              wrapMode: Text.WordWrap
            }

            Button {
              text: root.zoneRetryLabel(root.selectedZone)
              tooltipText: "Writes the mode this switch says to the fan controller again"
              fontSize: Style.font.bodySmall
              foreground: root.bar.foreground
              fontFamily: root.bar.fontFamily
              bordered: true
              radius: height / 2
              enabled: root.selectedZone !== null && !root.selectedZone.pendingApply && !root.identifyBusy
              onClicked: { if (root.svc && root.selectedZone) root.svc.retryZone(root.selectedZone.key) }
            }
          }

          Column {
            id: thresholds
            width: parent.width
            spacing: Style.space(16)
            enabled: root.customMode
            opacity: root.customMode ? 1.0 : 0.45

            Behavior on opacity { NumberAnimation { duration: 120 } }

            // The curve itself; drag a breakpoint to move it, or use the
            // sliders below — both commit through the same service calls.
            CurveGraph {
              width: parent.width
              height: Style.space(96)
              thresholds: root.selectedZone || ({ quietC: 45, rampC: 65, fullC: 80 })
              currentTemp: root.cpuTemperature
              lineColor: Color.accent
              foreground: root.bar.foreground
              onMoved: function(which, temp) { if (root.selectedZone) root.commitThreshold(root.selectedZone.key, which, temp) }
            }

            ThresholdSlider {
              width: parent.width
              label: "QUIET BELOW"
              caption: "Minimum duty (" + Model.MIN_DUTY + "%) until this temperature"
              value: root.selectedZone ? root.selectedZone.quietC : 45
              onCommitted: function(v) { if (root.svc && root.selectedZone) root.svc.setQuiet(root.selectedZone.key, v) }
            }

            ThresholdSlider {
              width: parent.width
              label: "RAMP TO " + Model.RAMP_DUTY + "% BY"
              caption: "Duty climbs from " + Model.MIN_DUTY + "% to " + Model.RAMP_DUTY + "% between quiet and here"
              value: root.selectedZone ? root.selectedZone.rampC : 65
              onCommitted: function(v) { if (root.svc && root.selectedZone) root.svc.setRamp(root.selectedZone.key, v) }
            }

            ThresholdSlider {
              width: parent.width
              label: "FULL SPEED AT"
              caption: "100% duty at or above this temperature"
              value: root.selectedZone ? root.selectedZone.fullC : 80
              onCommitted: function(v) { if (root.svc && root.selectedZone) root.svc.setFull(root.selectedZone.key, v) }
            }
          }
        }

        // ---------- Expanded: one card per fan ----------
        Flow {
          width: parent.width
          spacing: root.cardGap
          visible: root.expanded && root.reportingZones.length > 0

          Repeater {
            model: root.zoneKeys
            FanCard {}
          }
        }
      }
      }
    }
  }

  // Simple vector pinwheel so the bar icon and hero never depend on a Nerd
  // Font glyph being present. Spins continuously once the represented fan
  // has any duty, faster the harder it's running.
  component FanIcon: Item {
    id: icon
    property real dutyPercent: 0
    property color tint: Color.foreground
    property real iconSize: Style.font.icon

    width: iconSize
    height: iconSize
    implicitWidth: iconSize
    implicitHeight: iconSize

    Item {
      id: blades
      anchors.fill: parent

      Repeater {
        model: 3
        Rectangle {
          required property int index
          anchors.centerIn: parent
          width: parent.width * 0.92
          height: parent.height * 0.22
          radius: height / 2
          color: icon.tint
          rotation: index * 60
        }
      }

      Rectangle {
        anchors.centerIn: parent
        width: parent.width * 0.3
        height: width
        radius: width / 2
        color: icon.tint
      }

      RotationAnimation on rotation {
        running: icon.dutyPercent > 0
        loops: Animation.Infinite
        from: 0
        to: 360
        duration: Math.max(260, 2400 - icon.dutyPercent * 20)
      }
    }
  }

  // Simple vector thermometer, same reasoning as FanIcon: no Nerd Font glyph
  // dependency. Always static — the number next to it is the live reading.
  component TemperatureIcon: Item {
    id: tempIcon
    property color tint: Color.foreground
    property real iconSize: Style.font.icon

    width: iconSize
    height: iconSize
    implicitWidth: iconSize
    implicitHeight: iconSize

    readonly property real bulbSize: iconSize * 0.5
    readonly property real stemWidth: Math.max(2, iconSize * 0.26)

    Rectangle {
      id: stem
      width: tempIcon.stemWidth
      height: tempIcon.iconSize - tempIcon.bulbSize * 0.6
      radius: width / 2
      color: "transparent"
      border.color: tempIcon.tint
      border.width: Math.max(1, tempIcon.stemWidth * 0.32)
      anchors.horizontalCenter: parent.horizontalCenter
      anchors.top: parent.top
    }

    Rectangle {
      id: mercury
      width: Math.max(1, tempIcon.stemWidth * 0.42)
      height: stem.height * 0.5
      radius: width / 2
      color: tempIcon.tint
      anchors.horizontalCenter: parent.horizontalCenter
      anchors.bottom: bulb.top
      anchors.bottomMargin: -Math.round(tempIcon.bulbSize * 0.12)
    }

    Rectangle {
      id: bulb
      width: tempIcon.bulbSize
      height: tempIcon.bulbSize
      radius: width / 2
      color: tempIcon.tint
      anchors.horizontalCenter: parent.horizontalCenter
      anchors.bottom: parent.bottom
    }
  }

  // Scrolling area+line chart of the last few minutes of one series: CPU
  // temperature in the shared graph, RPM or duty in each fan card.
  component HistoryGraph: Item {
    id: graph
    property var history: []
    property real minValue: 0
    property real maxValue: 100
    property color lineColor: Color.accent
    property color foreground: Color.foreground
    property string currentLabel: ""   // top-right, accent: the live value
    property string scaleLabel: ""     // top-left, dim: what/which axis

    readonly property color gridColor: Qt.rgba(graph.foreground.r, graph.foreground.g, graph.foreground.b, 0.1)

    Canvas {
      id: canvas
      anchors.fill: parent

      onPaint: {
        var ctx = getContext("2d")
        ctx.clearRect(0, 0, width, height)
        ctx.strokeStyle = graph.gridColor
        ctx.lineWidth = 1
        for (var g = 1; g < 4; g++) {
          var gy = Math.round(height * g / 4) + 0.5
          ctx.beginPath()
          ctx.moveTo(0, gy)
          ctx.lineTo(width, gy)
          ctx.stroke()
        }

        var data = graph.history
        if (!data || data.length < 2) return

        var range = Math.max(1, graph.maxValue - graph.minValue)
        function xFor(i) { return (i / (data.length - 1)) * width }
        function yFor(v) {
          var t = Math.max(0, Math.min(1, (v - graph.minValue) / range))
          return height - t * height
        }

        ctx.beginPath()
        ctx.moveTo(xFor(0), height)
        for (var i = 0; i < data.length; i++) ctx.lineTo(xFor(i), yFor(data[i]))
        ctx.lineTo(xFor(data.length - 1), height)
        ctx.closePath()
        var gradient = ctx.createLinearGradient(0, 0, 0, height)
        gradient.addColorStop(0, Qt.rgba(graph.lineColor.r, graph.lineColor.g, graph.lineColor.b, 0.35))
        gradient.addColorStop(1, Qt.rgba(graph.lineColor.r, graph.lineColor.g, graph.lineColor.b, 0.02))
        ctx.fillStyle = gradient
        ctx.fill()

        ctx.beginPath()
        ctx.moveTo(xFor(0), yFor(data[0]))
        for (var j = 1; j < data.length; j++) ctx.lineTo(xFor(j), yFor(data[j]))
        ctx.lineWidth = Math.max(1, Style.space(2))
        ctx.strokeStyle = graph.lineColor
        ctx.stroke()

        var lastX = xFor(data.length - 1)
        var lastY = yFor(data[data.length - 1])
        ctx.beginPath()
        ctx.arc(lastX, lastY, Math.max(2, Style.space(3)), 0, Math.PI * 2)
        ctx.fillStyle = graph.lineColor
        ctx.fill()
      }
    }

    onHistoryChanged: canvas.requestPaint()
    onWidthChanged: canvas.requestPaint()
    onHeightChanged: canvas.requestPaint()
    Component.onCompleted: canvas.requestPaint()

    Text {
      textFormat: Text.PlainText
      visible: graph.currentLabel !== ""
      text: graph.currentLabel
      anchors.top: parent.top
      anchors.right: parent.right
      anchors.margins: Style.space(4)
      color: graph.lineColor
      font.bold: true
      font.pixelSize: Style.font.caption
    }

    Text {
      textFormat: Text.PlainText
      visible: graph.scaleLabel !== ""
      text: graph.scaleLabel
      anchors.top: parent.top
      anchors.left: parent.left
      anchors.margins: Style.space(4)
      color: Qt.darker(graph.foreground, 1.6)
      font.bold: true
      font.pixelSize: Style.font.caption
      font.letterSpacing: 1
    }
  }

  // Compact open-arc dial for the current fan duty, in the same visual
  // language as the network/disk speed-test dials.
  component FanGauge: Item {
    id: gauge
    property real value: 0
    property string caption: ""
    property color trackColor: Qt.rgba(1, 1, 1, 0.14)
    property color accentColor: Color.accent
    property color foreground: Color.foreground

    readonly property real dialStart: 135
    readonly property real dialSweep: 270
    readonly property real arcWidth: Math.max(2, Style.space(6))
    readonly property real arcRadius: Math.min(width, height) / 2 - arcWidth
    readonly property real fraction: Math.max(0, Math.min(1, shown / 100))

    property real shown: value
    onValueChanged: shown = value
    Behavior on shown { NumberAnimation { duration: 500; easing.type: Easing.OutCubic } }

    Shape {
      anchors.fill: parent
      preferredRendererType: Shape.CurveRenderer

      ShapePath {
        strokeWidth: gauge.arcWidth
        strokeColor: gauge.trackColor
        fillColor: "transparent"
        capStyle: ShapePath.RoundCap

        PathAngleArc {
          centerX: gauge.width / 2
          centerY: gauge.height / 2
          radiusX: gauge.arcRadius
          radiusY: gauge.arcRadius
          startAngle: gauge.dialStart
          sweepAngle: gauge.dialSweep
        }
      }

      ShapePath {
        strokeWidth: gauge.arcWidth
        strokeColor: gauge.fraction > 0.004 ? gauge.accentColor : "transparent"
        fillColor: "transparent"
        capStyle: ShapePath.RoundCap

        PathAngleArc {
          centerX: gauge.width / 2
          centerY: gauge.height / 2
          radiusX: gauge.arcRadius
          radiusY: gauge.arcRadius
          startAngle: gauge.dialStart
          sweepAngle: gauge.dialSweep * gauge.fraction
        }
      }
    }

    Column {
      anchors.centerIn: parent
      spacing: 0

      Text {
        textFormat: Text.PlainText
        anchors.horizontalCenter: parent.horizontalCenter
        text: Math.round(gauge.shown) + "%"
        color: gauge.foreground
        font.bold: true
        font.pixelSize: Style.font.title
      }

      Text {
        textFormat: Text.PlainText
        anchors.horizontalCenter: parent.horizontalCenter
        visible: gauge.caption !== ""
        text: gauge.caption
        color: Qt.darker(gauge.foreground, 1.4)
        font.pixelSize: Style.font.caption
      }
    }
  }

  // Header + value readout + slider, for one fan-curve temperature
  // breakpoint. Commits on release, same as every other slider in the kit.
  component ThresholdSlider: Column {
    id: thresholdRow
    property string label: ""
    property string caption: ""
    property real value: 0
    signal committed(real value)

    spacing: Style.space(6)

    Item {
      width: parent.width
      implicitHeight: Math.max(header.implicitHeight, valueText.implicitHeight)

      PanelSectionHeader {
        id: header
        text: thresholdRow.label
        foreground: root.bar.foreground
        fontFamily: root.bar.fontFamily
        anchors.left: parent.left
        anchors.verticalCenter: parent.verticalCenter
      }

      Text {
        id: valueText
        textFormat: Text.PlainText
        text: Model.formatTemp(slider.dragging ? slider.liveValue : thresholdRow.value)
        color: Qt.darker(root.bar.foreground, 1.4)
        font.family: root.bar.fontFamily
        font.pixelSize: Style.font.caption
        font.bold: true
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
      }
    }

    PanelSlider {
      id: slider
      bar: root.bar
      width: parent.width
      minimum: Model.TEMP_MIN
      maximum: Model.TEMP_MAX
      integer: true
      step: 1
      value: thresholdRow.value
      onReleased: function(v) { thresholdRow.committed(Math.round(v)) }
    }

    Text {
      textFormat: Text.PlainText
      width: parent.width
      text: thresholdRow.caption
      color: Qt.darker(root.bar.foreground, 1.5)
      font.family: root.bar.fontFamily
      font.pixelSize: Style.font.caption
      wrapMode: Text.WordWrap
    }
  }

  // The fan curve itself, duty against CPU temperature, with the three
  // breakpoints marked and the CPU's current position on it — so a glance
  // shows both where the thresholds sit and what duty they imply right now.
  // The breakpoints are also handles: drag one along the temperature axis
  // to move that threshold (their duty levels are fixed by the curve
  // shape — quiet/ramp/full are always MIN/RAMP/FULL duty). The drag
  // previews live and commits on release through `moved`, the same path
  // the steppers and sliders take, so ordering (quiet < ramp < full) is
  // enforced identically: dragging past a neighbour pushes it along.
  component CurveGraph: Item {
    id: curve
    property var thresholds: ({ quietC: 45, rampC: 65, fullC: 80 })
    property real currentTemp: -1
    property color lineColor: Color.accent
    property color foreground: Color.foreground
    signal moved(string which, int temp)   // which: "quiet" | "ramp" | "full"

    readonly property real inset: Math.max(3, Style.space(4))
    readonly property real plotW: Math.max(1, width - inset * 2)
    readonly property real plotH: Math.max(1, height - inset * 2)
    readonly property real hitRadius: Math.max(8, Style.space(12))
    readonly property color gridColor: Qt.rgba(curve.foreground.r, curve.foreground.g, curve.foreground.b, 0.1)
    readonly property var handleNames: ["quiet", "ramp", "full"]
    readonly property var handleLabels: ["Quiet", "Ramp", "Full"]

    // While a handle is being dragged the chart shows the would-be
    // thresholds rather than the committed ones.
    property var liveThresholds: null
    readonly property var shownThresholds: liveThresholds || thresholds
    readonly property var points: Model.curvePoints(shownThresholds)
    property int dragIndex: -1
    property int hoverIndex: -1
    readonly property int activeIndex: dragIndex >= 0 ? dragIndex : hoverIndex

    function xForTemp(temp) {
      var t = (temp - Model.TEMP_MIN) / Math.max(1, Model.TEMP_MAX - Model.TEMP_MIN)
      return inset + Math.max(0, Math.min(1, t)) * plotW
    }
    function yForDuty(duty) { return inset + plotH - Math.max(0, Math.min(1, duty / 100)) * plotH }
    function tempForX(x) {
      var t = (x - inset) / plotW
      return Model.clampTemp(Model.TEMP_MIN + Math.max(0, Math.min(1, t)) * (Model.TEMP_MAX - Model.TEMP_MIN), Model.TEMP_MIN)
    }
    // Breakpoint i (0 quiet, 1 ramp, 2 full) is points[i + 1].
    function handleX(i) { return xForTemp(points[i + 1].temp) }
    function handleY(i) { return yForDuty(points[i + 1].duty) }
    function handleAt(x, y) {
      var best = -1, bestD = curve.hitRadius
      for (var i = 0; i < 3; i++) {
        var d = Math.hypot(x - handleX(i), y - handleY(i))
        if (d <= bestD) { best = i; bestD = d }
      }
      return best
    }
    function previewFor(i, temp) {
      var base = curve.thresholds
      if (i === 0) return Model.setQuiet(base, temp)
      if (i === 1) return Model.setRamp(base, temp)
      return Model.setFull(base, temp)
    }
    function tempOf(i) {
      var t = curve.shownThresholds
      return i === 0 ? t.quietC : i === 1 ? t.rampC : t.fullC
    }

    Canvas {
      id: curveCanvas
      anchors.fill: parent

      onPaint: {
        var ctx = getContext("2d")
        ctx.clearRect(0, 0, width, height)

        ctx.strokeStyle = curve.gridColor
        ctx.lineWidth = 1
        for (var g = 1; g < 4; g++) {
          var gy = Math.round(curve.yForDuty(g * 25)) + 0.5
          ctx.beginPath(); ctx.moveTo(curve.inset, gy); ctx.lineTo(width - curve.inset, gy); ctx.stroke()
        }

        var pts = curve.points
        ctx.beginPath()
        ctx.moveTo(curve.xForTemp(pts[0].temp), curve.yForDuty(0))
        for (var i = 0; i < pts.length; i++) ctx.lineTo(curve.xForTemp(pts[i].temp), curve.yForDuty(pts[i].duty))
        ctx.lineTo(curve.xForTemp(pts[pts.length - 1].temp), curve.yForDuty(0))
        ctx.closePath()
        var gradient = ctx.createLinearGradient(0, 0, 0, height)
        gradient.addColorStop(0, Qt.rgba(curve.lineColor.r, curve.lineColor.g, curve.lineColor.b, 0.28))
        gradient.addColorStop(1, Qt.rgba(curve.lineColor.r, curve.lineColor.g, curve.lineColor.b, 0.02))
        ctx.fillStyle = gradient
        ctx.fill()

        ctx.beginPath()
        ctx.moveTo(curve.xForTemp(pts[0].temp), curve.yForDuty(pts[0].duty))
        for (var j = 1; j < pts.length; j++) ctx.lineTo(curve.xForTemp(pts[j].temp), curve.yForDuty(pts[j].duty))
        ctx.lineWidth = Math.max(1, Style.space(2))
        ctx.strokeStyle = curve.lineColor
        ctx.stroke()

        // Where the CPU sits on the curve right now (drawn under the
        // handles so a handle parked on it stays grabbable).
        if (curve.currentTemp > 0) {
          var cx = curve.xForTemp(curve.currentTemp)
          var cy = curve.yForDuty(Model.dutyForTemperature(curve.currentTemp, curve.shownThresholds))
          ctx.strokeStyle = Qt.rgba(curve.foreground.r, curve.foreground.g, curve.foreground.b, 0.45)
          ctx.lineWidth = 1
          ctx.setLineDash([3, 3])
          ctx.beginPath(); ctx.moveTo(Math.round(cx) + 0.5, curve.inset); ctx.lineTo(Math.round(cx) + 0.5, height - curve.inset); ctx.stroke()
          ctx.setLineDash([])
          ctx.beginPath()
          ctx.arc(cx, cy, Math.max(3, Style.space(4)), 0, Math.PI * 2)
          ctx.fillStyle = curve.lineColor
          ctx.fill()
          ctx.lineWidth = Math.max(1, Style.space(1.5))
          ctx.strokeStyle = curve.foreground
          ctx.stroke()
        }

        // Breakpoint handles: quiet, ramp, full. The hovered/dragged one is
        // drawn larger with an accent ring so it reads as grabbable.
        for (var b = 0; b < 3; b++) {
          var hot = b === curve.activeIndex && curve.enabled
          var r = Math.max(2, Style.space(hot ? 5 : 3))
          ctx.beginPath()
          ctx.arc(curve.handleX(b), curve.handleY(b), r, 0, Math.PI * 2)
          ctx.fillStyle = curve.foreground
          ctx.fill()
          if (hot) {
            ctx.lineWidth = Math.max(1, Style.space(2))
            ctx.strokeStyle = curve.lineColor
            ctx.stroke()
          }
        }
      }
    }

    onPointsChanged: curveCanvas.requestPaint()
    onCurrentTempChanged: curveCanvas.requestPaint()
    onActiveIndexChanged: curveCanvas.requestPaint()
    onWidthChanged: curveCanvas.requestPaint()
    onHeightChanged: curveCanvas.requestPaint()
    Component.onCompleted: curveCanvas.requestPaint()

    MouseArea {
      id: handleArea
      anchors.fill: parent
      hoverEnabled: true
      // The chart lives inside a vertically scrolling Flickable; a handle
      // drag is ours from the first pixel, whatever direction it wanders.
      preventStealing: true
      cursorShape: curve.activeIndex >= 0 ? Qt.SizeHorCursor : Qt.ArrowCursor
      acceptedButtons: Qt.LeftButton

      onPressed: function(mouse) {
        var i = curve.handleAt(mouse.x, mouse.y)
        if (i < 0) { mouse.accepted = false; return }
        curve.dragIndex = i
        curve.liveThresholds = curve.previewFor(i, curve.tempForX(mouse.x))
      }
      onPositionChanged: function(mouse) {
        if (curve.dragIndex >= 0) {
          curve.liveThresholds = curve.previewFor(curve.dragIndex, curve.tempForX(mouse.x))
        } else {
          curve.hoverIndex = curve.handleAt(mouse.x, mouse.y)
        }
      }
      onReleased: function(mouse) {
        if (curve.dragIndex < 0) return
        var i = curve.dragIndex
        var temp = curve.tempForX(mouse.x)
        curve.dragIndex = -1
        curve.liveThresholds = null
        curve.hoverIndex = curve.handleAt(mouse.x, mouse.y)
        curve.moved(curve.handleNames[i], temp)
      }
      onCanceled: { curve.dragIndex = -1; curve.liveThresholds = null }
      onExited: { if (curve.dragIndex < 0) curve.hoverIndex = -1 }
    }

    Text {
      textFormat: Text.PlainText
      anchors.top: parent.top
      anchors.left: parent.left
      anchors.margins: Style.space(4)
      text: Model.TEMP_MIN + "–" + Model.TEMP_MAX + "°C"
      color: Qt.darker(curve.foreground, 1.6)
      font.pixelSize: Style.font.caption
      font.bold: true
      font.letterSpacing: 1
    }

    // Bottom-right: the curve only sits low on the left (below quiet), so this
    // corner never collides with it the way the top-right (full speed) would.
    Text {
      textFormat: Text.PlainText
      visible: curve.currentTemp > 0 && curve.activeIndex < 0
      anchors.bottom: parent.bottom
      anchors.right: parent.right
      anchors.margins: Style.space(4)
      text: Model.formatTemp(curve.currentTemp) + " → " + Model.formatDuty(Model.dutyForTemperature(curve.currentTemp, curve.shownThresholds))
      color: curve.lineColor
      font.pixelSize: Style.font.caption
      font.bold: true
    }

    // Floating readout for the handle under the pointer / being dragged.
    Rectangle {
      id: handleTip
      visible: curve.activeIndex >= 0 && curve.enabled
      readonly property int idx: Math.max(0, curve.activeIndex)
      readonly property real hx: curve.handleX(idx)
      readonly property real hy: curve.handleY(idx)
      width: tipText.implicitWidth + Style.space(8)
      height: tipText.implicitHeight + Style.space(4)
      radius: Style.space(4)
      color: Color.tooltip.background
      border.color: Color.tooltip.border
      border.width: 1
      x: Math.max(0, Math.min(curve.width - width, hx - width / 2))
      y: hy - height - Style.space(10) < 0 ? hy + Style.space(10) : hy - height - Style.space(10)

      Text {
        id: tipText
        textFormat: Text.PlainText
        anchors.centerIn: parent
        text: curve.handleLabels[handleTip.idx] + " · " + Model.formatTemp(curve.tempOf(handleTip.idx))
        color: Color.tooltip.text
        font.pixelSize: Style.font.caption
        font.bold: true
      }
    }
  }

  // One curve breakpoint as a label, its value, and −/+ steppers — the
  // card-sized stand-in for ThresholdSlider. Click steps 1 °C, right-click 5.
  component ThresholdStepper: Item {
    id: stepper
    property string label: ""
    property real value: 0
    signal step(int delta)

    implicitHeight: Math.max(stepLabel.implicitHeight, stepRow.implicitHeight)

    Text {
      id: stepLabel
      textFormat: Text.PlainText
      anchors.left: parent.left
      anchors.right: stepRow.left
      anchors.rightMargin: Style.space(6)
      anchors.verticalCenter: parent.verticalCenter
      text: stepper.label
      color: Qt.darker(root.bar.foreground, 1.4)
      font.family: root.bar.fontFamily
      font.pixelSize: Style.font.caption
      elide: Text.ElideRight
    }

    Row {
      id: stepRow
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      spacing: Style.space(4)

      Text {
        textFormat: Text.PlainText
        anchors.verticalCenter: parent.verticalCenter
        text: Model.formatTemp(stepper.value)
        color: root.bar.foreground
        font.family: root.bar.fontFamily
        font.pixelSize: Style.font.bodySmall
        font.bold: true
        width: implicitWidth + Style.space(4)
        horizontalAlignment: Text.AlignRight
      }

      Button {
        text: "−"
        tooltipText: "−1 °C (right-click: −5 °C)"
        fontSize: Style.font.bodySmall
        foreground: root.bar.foreground
        fontFamily: root.bar.fontFamily
        bordered: true
        radius: height / 2
        horizontalPadding: Style.space(7)
        verticalPadding: Style.space(1)
        onClicked: stepper.step(-1)
        onRightClicked: stepper.step(-5)
      }

      Button {
        text: "+"
        tooltipText: "+1 °C (right-click: +5 °C)"
        fontSize: Style.font.bodySmall
        foreground: root.bar.foreground
        fontFamily: root.bar.fontFamily
        bordered: true
        radius: height / 2
        horizontalPadding: Style.space(7)
        verticalPadding: Style.space(1)
        onClicked: stepper.step(1)
        onRightClicked: stepper.step(5)
      }
    }
  }

  // One fan in the expanded view: name (editable) and mode switch, live
  // duty + RPM, a speed sparkline, and — on a custom curve — the curve with
  // its thresholds and where the CPU currently sits on it.
  component FanCard: BorderSurface {
    id: card
    required property var modelData
    readonly property string zoneKey: String(modelData)
    readonly property var fan: root.zoneByKey(zoneKey) || root.placeholderZone
    readonly property bool custom: fan.mode === "custom"
    readonly property bool hasTach: fan.fanPath !== ""
    readonly property bool selected: zoneKey === root.selectedZoneKey
    readonly property color dim: Qt.darker(root.bar.foreground, 1.4)

    // The compact view (and the "Fan Speed" bar readout) follow the
    // service's selected zone. Every edit on a card selects that fan first,
    // so collapsing right after lands on the fan just changed rather than
    // on whichever one the selector last pointed at.
    function focusZone() { if (root.svc) root.svc.selectZone(card.zoneKey) }

    width: root.cardWidth
    implicitHeight: cardBody.implicitHeight + card.contentTopInset + card.contentBottomInset
    padding: Style.space(12)
    // Deliberately rounded regardless of the theme's corner setting: the
    // cards are tiles on the panel, not chrome, and read better rounded.
    radius: root.cardRadius
    color: card.selected
      ? Style.selectedFillFor(root.bar.foreground, Color.accent)
      : Style.normalFillFor(root.bar.foreground, Color.accent)
    borderSpec: Border.controlSpec(card.selected ? "hover-cursor" : "normal", root.bar.foreground, Color.accent)

    Behavior on color { ColorAnimation { duration: 120 } }

    // Clicking the card's empty space selects it too; child controls take
    // their own presses first, so this only sees taps they left alone.
    TapHandler {
      acceptedButtons: Qt.LeftButton
      onTapped: card.focusZone()
    }

    Column {
      id: cardBody
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.top: parent.top
      anchors.leftMargin: card.contentLeftInset
      anchors.rightMargin: card.contentRightInset
      anchors.topMargin: card.contentTopInset
      spacing: Style.space(8)

      // ---- name + mode ----
      RowLayout {
        width: parent.width
        spacing: Style.space(8)

        FanIcon {
          Layout.alignment: Qt.AlignVCenter
          iconSize: Style.font.heading
          tint: root.bar.foreground
          dutyPercent: card.fan.duty > 0 ? card.fan.duty : 0
        }

        TextField {
          id: cardName
          Layout.fillWidth: true
          Layout.alignment: Qt.AlignVCenter
          placeholderText: card.fan.autoLabel
          foreground: root.bar.foreground
          font.family: root.bar.fontFamily
          font.pixelSize: Style.font.subtitle
          font.bold: true
          verticalPadding: Style.space(3)

          // Same rule as the compact view's name field: never bind `text`
          // to the zone, or every 2s poll would overwrite a draft mid-edit.
          readonly property string savedLabel: card.fan.customLabel
          Component.onCompleted: text = savedLabel
          onSavedLabelChanged: if (!activeFocus) text = savedLabel
          onActiveFocusChanged: if (activeFocus) card.focusZone()
          onEditingFinished: {
            if (root.svc) root.svc.setLabel(card.zoneKey, text)
            text = savedLabel
          }
        }

        ToggleSwitch {
          Layout.alignment: Qt.AlignVCenter
          checked: card.custom
          rounded: true   // pill shape regardless of theme corners, like the compact view's switch
          foreground: root.bar.foreground
          trackHeight: Math.max(18, Math.round(Style.spacing.controlHeight * 0.5))
          cursorPad: Style.space(3)
          onToggled: {
            card.focusZone()
            if (root.svc) root.svc.setMode(card.zoneKey, card.custom ? "auto" : "custom")
          }

          PanelToolTip {
            visible: parent.containsMouse
            text: card.custom ? "Custom curve — this plugin drives the duty" : "Auto — the board's own fan curve"
            fontFamily: root.bar.fontFamily
          }
        }
      }

      // ---- live readout ----
      Item {
        width: parent.width
        implicitHeight: dutyReadout.implicitHeight

        Text {
          id: dutyReadout
          textFormat: Text.PlainText
          anchors.left: parent.left
          text: Model.formatDuty(card.fan.duty)
          color: root.bar.foreground
          font.family: root.bar.fontFamily
          font.pixelSize: Style.font.heading
          font.bold: true
        }

        Text {
          textFormat: Text.PlainText
          anchors.right: parent.right
          anchors.baseline: dutyReadout.baseline
          text: card.hasTach ? Model.formatRpm(card.fan.rpm) : "no tachometer"
          color: card.dim
          font.family: root.bar.fontFamily
          font.pixelSize: Style.font.bodySmall
        }
      }

      Text {
        textFormat: Text.PlainText
        width: parent.width
        readonly property string warning: root.zoneWarning(card.fan)
        text: card.fan.identifying
          ? "Identifying — held at 100% for a few seconds"
          : warning !== ""
            ? warning
            : card.custom
              ? "Custom curve · " + Model.formatTemp(root.cpuTemperature) + " → " + Model.formatDuty(Model.dutyForTemperature(root.cpuTemperature > 0 ? root.cpuTemperature : Model.TEMP_MAX, card.fan))
              : "Auto — the board's own fan curve is in charge"
        color: card.fan.identifying ? Color.accent : warning !== "" ? Color.urgent : Qt.darker(root.bar.foreground, 1.6)
        font.family: root.bar.fontFamily
        font.pixelSize: Style.font.caption
        wrapMode: warning !== "" ? Text.WordWrap : Text.NoWrap
        elide: warning !== "" ? Text.ElideNone : Text.ElideRight
      }

      // ---- speed sparkline ----
      HistoryGraph {
        width: parent.width
        height: Style.space(64)
        history: card.hasTach ? card.fan.rpmHistory : card.fan.dutyHistory
        minValue: 0
        maxValue: card.hasTach ? Model.historyCeiling(card.fan.rpmHistory, 500) : 100
        lineColor: Color.accent
        foreground: root.bar.foreground
        scaleLabel: card.hasTach
          ? ("≤ " + Math.round(maxValue).toLocaleString() + " RPM")
          : "DUTY %"
      }

      // ---- curve + thresholds (custom mode only) ----
      Column {
        width: parent.width
        spacing: Style.space(6)
        visible: card.custom

        PanelSectionHeader {
          text: "CURVE · CPU TEMPERATURE"
          foreground: root.bar.foreground
          fontFamily: root.bar.fontFamily
        }

        CurveGraph {
          width: parent.width
          height: Style.space(80)
          thresholds: card.fan
          currentTemp: root.cpuTemperature
          lineColor: Color.accent
          foreground: root.bar.foreground
          onMoved: function(which, temp) { card.focusZone(); root.commitThreshold(card.zoneKey, which, temp) }
        }

        ThresholdStepper {
          width: parent.width
          label: "Quiet below (" + Model.MIN_DUTY + "%)"
          value: card.fan.quietC
          onStep: function(delta) { card.focusZone(); if (root.svc) root.svc.setQuiet(card.zoneKey, card.fan.quietC + delta) }
        }

        ThresholdStepper {
          width: parent.width
          label: "Ramp to " + Model.RAMP_DUTY + "% by"
          value: card.fan.rampC
          onStep: function(delta) { card.focusZone(); if (root.svc) root.svc.setRamp(card.zoneKey, card.fan.rampC + delta) }
        }

        ThresholdStepper {
          width: parent.width
          label: "Full speed at"
          value: card.fan.fullC
          onStep: function(delta) { card.focusZone(); if (root.svc) root.svc.setFull(card.zoneKey, card.fan.fullC + delta) }
        }
      }

      // ---- actions ----
      RowLayout {
        width: parent.width
        spacing: Style.space(8)

        Button {
          text: card.fan.identifying ? "Identifying…" : "Identify"
          tooltipText: "Ramps this fan to 100% for a few seconds so you can tell which one it is"
          fontSize: Style.font.caption
          foreground: root.bar.foreground
          fontFamily: root.bar.fontFamily
          bordered: true
          radius: height / 2
          enabled: card.fan.key !== "" && !root.identifyBusy
          onClicked: { card.focusZone(); if (root.svc) root.svc.identifyZone(card.zoneKey) }
        }

        Button {
          visible: root.zoneWarning(card.fan) !== ""
          text: root.zoneRetryLabel(card.fan)
          tooltipText: "Writes the mode the switch says to the fan controller again"
          fontSize: Style.font.caption
          foreground: Color.urgent
          fontFamily: root.bar.fontFamily
          bordered: true
          radius: height / 2
          enabled: !card.fan.pendingApply && !root.identifyBusy
          onClicked: { card.focusZone(); if (root.svc) root.svc.retryZone(card.zoneKey) }
        }

        Text {
          Layout.fillWidth: true
          textFormat: Text.PlainText
          text: card.fan.key
          color: Qt.darker(root.bar.foreground, 1.6)
          font.family: root.bar.fontFamily
          font.pixelSize: Style.font.caption
          horizontalAlignment: Text.AlignRight
          elide: Text.ElideLeft
        }
      }
    }
  }
}
