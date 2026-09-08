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
  // is the subset Service has actually seen spin (see Model.nextUnpluggedState),
  // and the only one offered as a selectable/controllable fan.
  readonly property var connectedZones: root.zones.filter(function(z) { return !z.unplugged })
  readonly property bool available: svc ? svc.available : false
  readonly property bool detecting: svc ? svc.detecting : false
  readonly property string detectError: svc ? svc.detectError : ""
  readonly property real cpuTemperature: svc ? svc.cpuTemperature : -1
  readonly property var tempHistory: svc ? svc.tempHistory : []
  readonly property string selectedZoneKey: svc ? svc.selectedZoneKey : ""
  readonly property var selectedZone: {
    var pool = root.connectedZones
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
      : (root.zones.length > 0 ? " · no fan currently connected" : "")

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
    contentWidth: panel.fittedContentWidth(Style.space(380))
    contentHeight: panel.fittedContentHeight(column.implicitHeight)

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }

      Column {
        id: column
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        spacing: Style.space(14)

        // ---------- Hero ----------
        PanelHero {
          width: parent.width
          title: "Cooler Control"
          meta: "CPU " + Model.formatTemp(root.cpuTemperature) + root.statusSuffix
          detail: root.selectedZone ? (root.customMode ? "CUSTOM CURVE" : "AUTO") : ""
          foreground: root.bar.foreground
          fontFamily: root.bar.fontFamily
          iconComponent: Component {
            FanIcon {
              iconSize: Style.font.display
              tint: root.bar.foreground
              dutyPercent: root.topZone ? root.topZone.duty : 0
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
          visible: !root.available || root.connectedZones.length === 0

          Text {
            width: parent.width
            text: !root.available
              ? "No pwm-capable fan controller was found under /sys/class/hwmon. "
                + "Most desktop boards expose one once lm_sensors probes and loads "
                + "the right Super I/O driver (nct6775, it87, ...)."
              : "Found " + root.zones.length + " fan header" + (root.zones.length === 1 ? "" : "s")
                + ", but none of them seem to have a fan plugged in — driving them "
                + "hasn't produced any RPM signal. Reseat the cable or try a different "
                + "header if you expected one here."
            color: Qt.darker(root.bar.foreground, 1.4)
            font.family: root.bar.fontFamily
            font.pixelSize: Style.font.caption
            wrapMode: Text.WordWrap
          }

          Text {
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
        Row {
          width: parent.width
          spacing: Style.space(8)
          visible: root.connectedZones.length > 1

          Repeater {
            model: root.connectedZones
            Button {
              required property var modelData
              text: modelData.label
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
          visible: root.selectedZone !== null

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
              text: root.selectedZone ? root.selectedZone.customLabel : ""
              placeholderText: root.selectedZone ? root.selectedZone.autoLabel : ""
              foreground: root.bar.foreground
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.bodySmall
              verticalPadding: Style.space(4)
              onEditingFinished: { if (root.svc && root.selectedZone) root.svc.setLabel(root.selectedZone.key, text) }
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
              ? root.selectedZone.key + (root.selectedZone.fanPath !== "" ? " · has tachometer" : " · no tachometer reading")
              : ""
            color: Qt.darker(root.bar.foreground, 1.6)
            font.family: root.bar.fontFamily
            font.pixelSize: Style.font.caption
          }
        }

        // ---------- Graph + gauge ----------
        RowLayout {
          width: parent.width
          spacing: Style.space(14)
          visible: root.available || root.cpuTemperature > 0

          TemperatureGraph {
            Layout.fillWidth: true
            Layout.preferredHeight: Style.space(96)
            history: root.tempHistory
            lineColor: Color.accent
            foreground: root.bar.foreground
            currentLabel: Model.formatTemp(root.cpuTemperature)
          }

          FanGauge {
            visible: root.selectedZone !== null
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

        // ---------- Mode + curve ----------
        Column {
          width: parent.width
          spacing: Style.space(14)
          visible: root.selectedZone !== null

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

          Column {
            id: thresholds
            width: parent.width
            spacing: Style.space(16)
            enabled: root.customMode
            opacity: root.customMode ? 1.0 : 0.45

            Behavior on opacity { NumberAnimation { duration: 120 } }

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

  // Scrolling area+line chart of the last few minutes of CPU temperature.
  component TemperatureGraph: Item {
    id: graph
    property var history: []
    property real minValue: 20
    property real maxValue: 100
    property color lineColor: Color.accent
    property color foreground: Color.foreground
    property string currentLabel: ""

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
}
