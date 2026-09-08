import QtQuick
import Quickshell
import Quickshell.Io
import "Model.js" as Model

// Polls CPU temperature and every pwm-capable fan the system exposes over
// sysfs (/sys/class/hwmon), and — for zones the user switches to "custom" —
// writes a software fan curve back to the hardware. Reads never need
// privilege; writes to pwm*/pwm*_enable do, so they go through pkexec. To
// keep the unattended curve loop from turning into a password prompt every
// couple of seconds, its writes only fire when the target duty actually
// drifts (see applyCurveTick) and are throttled to one attempt per zone per
// applyMinIntervalMs; a direct user action (mode toggle, slider release)
// always applies immediately instead.
QtObject {
  id: root

  // Absolute paths for every executable this file runs, privileged or not —
  // a bare name relies on PATH resolution, which a privileged pkexec/bash
  // invocation should never trust (the standard "don't let PATH pick what
  // runs as root" hardening, matching the absolute pkexec target already
  // used elsewhere in this marketplace, e.g. quickshell.spotify's setup
  // script's `pkexec /usr/bin/pacman`).
  readonly property string _pkexecBin: "/usr/bin/pkexec"
  readonly property string _bashBin: "/usr/bin/bash"
  readonly property string _shBin: "/usr/bin/sh"
  readonly property string _mkdirBin: "/usr/bin/mkdir"
  readonly property string _sensorsDetectBin: "/usr/bin/sensors-detect"

  property string cpuTemperaturePath: ""
  property real cpuTemperature: -1
  property var tempHistory: []
  // [{ key, label, autoLabel, customLabel, fanPath, pwmPath, enablePath,
  //    faultPath, originalEnable, rpm, duty, unplugged, unpluggedStreak,
  //    mode, quietC, rampC, fullC, pendingApply, identifying,
  //    lastAttemptAtMs, lastAppliedDuty }]
  property var fanZones: []
  property string selectedZoneKey: ""
  property bool detecting: false
  property string detectError: ""
  property bool stateReady: false

  readonly property bool available: fanZones.length > 0
  readonly property int applyMinIntervalMs: 15000
  readonly property int applyHysteresis: 3   // percentage points

  property int updateMs: 2000

  // Privileged writes (pwm*/pwm*_enable) are serialized through one pkexec
  // process at a time, and a zone's lastAppliedDuty only advances once that
  // write actually exits 0 — an optimistic update here would let a
  // cancelled/failed pkexec prompt silently stop the curve from ever
  // retrying, since the next tick would see no drift against a duty the
  // hardware never received.
  property var _writeQueue: []
  property bool _writeBusy: false

  readonly property string configDir: (Quickshell.env("XDG_CONFIG_HOME")
    || (Quickshell.env("HOME") + "/.config")) + "/eduard.cooler-control"
  readonly property string configPath: configDir + "/state.json"

  function zoneByKey(key) {
    for (var i = 0; i < fanZones.length; i++)
      if (fanZones[i].key === key) return fanZones[i]
    return null
  }

  function replaceZone(key, patch) {
    fanZones = fanZones.map(function(z) {
      if (z.key !== key) return z
      var next = {}
      for (var k in z) next[k] = z[k]
      for (var p in patch) next[p] = patch[p]
      return next
    })
  }

  // ---------------------------------------------------------- persistence

  function defaultThresholds() {
    return { quietC: 45, rampC: 65, fullC: 80 }
  }

  function persistedStateFor(key) {
    var stored = root._persisted && root._persisted.zones ? root._persisted.zones[key] : null
    var thresholds = Model.normalizeThresholds(stored || defaultThresholds())
    return {
      mode: (stored && stored.mode === "custom") ? "custom" : "auto",
      quietC: thresholds.quietC,
      rampC: thresholds.rampC,
      fullC: thresholds.fullC,
      customLabel: (stored && typeof stored.customLabel === "string") ? stored.customLabel : ""
    }
  }

  function saveState() {
    var zones = {}
    for (var i = 0; i < fanZones.length; i++) {
      var z = fanZones[i]
      zones[z.key] = {
        mode: z.mode, quietC: z.quietC, rampC: z.rampC, fullC: z.fullC,
        customLabel: z.customLabel || ""
      }
    }
    root._persisted = { zones: zones }
    try {
      stateFile.setText(JSON.stringify(root._persisted, null, 2))
    } catch (error) {
      // Best-effort — losing a pending save just means defaults reload next time.
    }
  }

  property var _persisted: ({ zones: {} })

  // ------------------------------------------------------------- actions

  function selectZone(key) {
    if (zoneByKey(key)) selectedZoneKey = key
  }

  function setMode(key, mode) {
    var zone = zoneByKey(key)
    if (!zone) return
    var next = mode === "custom" ? "custom" : "auto"
    if (next === zone.mode) return
    replaceZone(key, { mode: next })
    saveState()
    if (next === "auto") restoreAuto(zoneByKey(key))
    else applyDutyFor(zoneByKey(key))
  }

  // Empty label reverts display to the auto-guessed one (hwmon's own
  // fanN_label if the board reports one, else "CPU Fan" for the first zone
  // found and "Case Fan N" after that) — sysfs has no notion of physical
  // position, so anything more specific (front/back/top) has to come from
  // the user actually looking at or listening to the fan Identify spins up.
  function setLabel(key, label) {
    var zone = zoneByKey(key)
    if (!zone) return
    var trimmed = String(label || "").trim()
    replaceZone(key, { customLabel: trimmed, label: trimmed || zone.autoLabel })
    saveState()
  }

  function setQuiet(key, value) {
    setThresholds(key, Model.setQuiet, value)
  }
  function setRamp(key, value) {
    setThresholds(key, Model.setRamp, value)
  }
  function setFull(key, value) {
    setThresholds(key, Model.setFull, value)
  }

  function setThresholds(key, mutator, value) {
    var zone = zoneByKey(key)
    if (!zone) return
    var next = mutator({ quietC: zone.quietC, rampC: zone.rampC, fullC: zone.fullC }, value)
    replaceZone(key, next)
    saveState()
    if (zone.mode === "custom") applyDutyFor(zoneByKey(key))
  }

  function refresh() {
    if (readProcess.running) return
    var args = [root._shBin, "-c", root._readScript, "sh", root.cpuTemperaturePath, String(root.fanZones.length)]
    for (var i = 0; i < root.fanZones.length; i++) {
      args.push(root.fanZones[i].fanPath || "")
      args.push(root.fanZones[i].pwmPath || "")
      args.push(root.fanZones[i].faultPath || "")
    }
    readProcess.command = args
    readProcess.running = true
  }

  function applyReadResults(raw) {
    var lines = String(raw || "").trim().split("\n")
    var zoneIndex = 0
    var nextZones = fanZones.slice()
    for (var i = 0; i < lines.length; i++) {
      var fields = lines[i].split("\t")
      if (fields[0] === "cpu") {
        var millideg = Number(fields[1])
        cpuTemperature = isFinite(millideg) && millideg > 0 ? millideg / 1000 : -1
        if (cpuTemperature > 0) tempHistory = Model.pushHistory(tempHistory, cpuTemperature)
      } else if (fields[0] === "zone" && zoneIndex < nextZones.length) {
        var rpm = Number(fields[1])
        var raw255 = Number(fields[2])
        var faultRaw = fields[3]
        var z = nextZones[zoneIndex]
        nextZones[zoneIndex] = (function(zone) {
          var copy = {}
          for (var k in zone) copy[k] = zone[k]
          copy.rpm = isFinite(rpm) && rpm >= 0 ? rpm : -1
          copy.duty = isFinite(raw255) ? Model.rawToDuty(raw255) : -1
          var next = Model.nextUnpluggedState(
            { unplugged: zone.unplugged, streak: zone.unpluggedStreak },
            { rpm: copy.rpm, duty: copy.duty, fault: faultRaw === "1" }
          )
          copy.unplugged = next.unplugged
          copy.unpluggedStreak = next.streak
          return copy
        })(z)
        zoneIndex++
      }
    }
    fanZones = nextZones
    reconcileSelectedZone()
    applyCurveTick()
  }

  // If the selected zone just got flagged unplugged and a connected one
  // exists, hand selection to that one rather than leaving the panel
  // pointed at a fan the user can no longer act on.
  function reconcileSelectedZone() {
    var current = zoneByKey(selectedZoneKey)
    if (current && !current.unplugged) return
    for (var i = 0; i < fanZones.length; i++) {
      if (!fanZones[i].unplugged) { selectedZoneKey = fanZones[i].key; return }
    }
  }

  // Runs every refresh tick. A zone in "custom" mode only gets a write
  // queued when its target duty has actually drifted from the last
  // *confirmed* duty by more than the hysteresis band, and never while a
  // write for it is still in flight or within applyMinIntervalMs of the
  // last attempt — so a steady temperature settles into silence rather
  // than re-authenticating on every poll.
  function applyCurveTick() {
    var now = Date.now()
    for (var i = 0; i < fanZones.length; i++) {
      var z = fanZones[i]
      if (z.mode !== "custom" || z.pendingApply || z.identifying) continue
      var target = Model.dutyForTemperature(root.cpuTemperature > 0 ? root.cpuTemperature : Model.TEMP_MAX, z)
      var drift = Math.abs(target - (z.lastAppliedDuty === undefined ? -100 : z.lastAppliedDuty))
      var dueForRetry = !z.lastAttemptAtMs || (now - z.lastAttemptAtMs) >= applyMinIntervalMs
      if (drift >= applyHysteresis && dueForRetry) applyDutyFor(z, target)
    }
  }

  // Explicit user actions (mode flip, slider release) call this directly and
  // always queue immediately, bypassing applyMinIntervalMs — that throttle
  // only paces the unattended curve loop above.
  function applyDutyFor(zone, targetOverride) {
    if (!zone || !zone.pwmPath || zone.pendingApply || zone.identifying) return
    var target = targetOverride !== undefined ? targetOverride
      : Model.dutyForTemperature(root.cpuTemperature > 0 ? root.cpuTemperature : Model.TEMP_MAX, zone)
    replaceZone(zone.key, { pendingApply: true, lastAttemptAtMs: Date.now() })
    enqueueWrite({
      kind: "duty", zoneKey: zone.key, targetDuty: target,
      pwmPath: zone.pwmPath, enablePath: zone.enablePath || "", raw: Model.dutyToRaw(target)
    })
  }

  function restoreAuto(zone) {
    if (!zone || !zone.enablePath || zone.originalEnable === "" || zone.pendingApply || zone.identifying) return
    replaceZone(zone.key, { pendingApply: true, lastAttemptAtMs: Date.now() })
    enqueueWrite({ kind: "restore", zoneKey: zone.key, enablePath: zone.enablePath, value: zone.originalEnable })
  }

  readonly property int identifyDurationMs: 4000
  property string _identifyingZoneKey: ""
  readonly property bool identifyBusy: fanZones.some(function(z) { return z.identifying })

  // Ramps one fan to 100% for a few seconds so the user can tell which
  // physical fan it is by ear or by eye, then hands it back to whatever was
  // driving it before (the software curve, or the board's own auto logic).
  // sysfs has no concept of "front"/"back"/"CPU" beyond whatever label the
  // board's own driver happens to report, so this — plus the rename field
  // in the panel — is the only reliable way to tell zones apart.
  function identifyZone(key) {
    if (root._identifyingZoneKey !== "") return
    var zone = zoneByKey(key)
    if (!zone || !zone.pwmPath || zone.pendingApply || zone.identifying) return
    root._identifyingZoneKey = key
    replaceZone(key, { identifying: true })
    enqueueWrite({
      kind: "identify", zoneKey: key,
      pwmPath: zone.pwmPath, enablePath: zone.enablePath || "", raw: Model.dutyToRaw(100)
    })
  }

  function _scheduleIdentifyRevert(key) {
    identifyRevertTimer.zoneKey = key
    identifyRevertTimer.restart()
  }

  function _finishIdentify(key) {
    if (root._identifyingZoneKey === key) root._identifyingZoneKey = ""
    replaceZone(key, { identifying: false })
    var zone = zoneByKey(key)
    if (!zone) return
    if (zone.mode === "custom") applyDutyFor(zone)
    else restoreAuto(zone)
  }

  function enqueueWrite(item) {
    _writeQueue.push(item)
    pumpWriteQueue()
  }

  function pumpWriteQueue() {
    if (_writeBusy || _writeQueue.length === 0) return
    _writeBusy = true
    var item = _writeQueue.shift()
    writeProcess.currentItem = item
    writeProcess.command = (item.kind === "duty" || item.kind === "identify")
      ? [root._pkexecBin, root._bashBin, "-c", root._writeDutyScript, "bash", item.pwmPath, item.enablePath, String(item.raw)]
      : [root._pkexecBin, root._bashBin, "-c", root._writeValueScript, "bash", item.enablePath, item.value]
    writeProcess.running = true
  }

  function detectFanController() {
    if (detecting) return
    detecting = true
    detectError = ""
    sensorsDetectProcess.running = true
  }

  function runDetection() {
    if (detectProcess.running) return
    detectProcess.running = true
  }

  // The very first zone with no hwmon-reported label is guessed as the CPU
  // fan (the overwhelmingly common convention: a Super I/O chip's first pwm
  // header is wired to CPU_FAN), and every one after that as "Case Fan N".
  // This is a guess, not a fact sysfs can confirm — the rename field lets
  // the user correct it, and Identify lets them find out which is which by
  // ear/eye in the first place.
  function applyDetection(raw) {
    var cpuPath = ""
    var found = []
    var cpuFanGuessed = false
    var caseFanCounter = 0
    var lines = String(raw || "").trim().split("\n")
    for (var i = 0; i < lines.length; i++) {
      var fields = lines[i].split("\t")
      if (fields[0] === "cpu" && cpuPath === "") {
        cpuPath = fields[1] || ""
      } else if (fields[0] === "zone") {
        var key = fields[1] || ""
        var sensorLabel = (fields[2] || "").trim()
        var pwmPath = fields[3] || ""
        var enablePath = fields[4] || ""
        var fanPath = fields[5] || ""
        var originalEnable = fields[6] !== undefined ? fields[6] : ""
        var faultPath = fields[7] || ""
        if (!key || !pwmPath) continue

        var autoLabel
        if (sensorLabel !== "") {
          autoLabel = sensorLabel
        } else if (!cpuFanGuessed) {
          autoLabel = "CPU Fan"
          cpuFanGuessed = true
        } else {
          caseFanCounter++
          autoLabel = "Case Fan " + caseFanCounter
        }

        var persisted = persistedStateFor(key)
        var existing = zoneByKey(key)
        found.push({
          key: key,
          autoLabel: autoLabel,
          customLabel: persisted.customLabel,
          label: persisted.customLabel || autoLabel,
          fanPath: fanPath,
          pwmPath: pwmPath,
          enablePath: enablePath,
          faultPath: faultPath,
          originalEnable: existing ? existing.originalEnable : originalEnable,
          rpm: existing ? existing.rpm : -1,
          duty: existing ? existing.duty : -1,
          unplugged: existing ? existing.unplugged : false,
          unpluggedStreak: existing ? existing.unpluggedStreak : 0,
          mode: persisted.mode,
          quietC: persisted.quietC,
          rampC: persisted.rampC,
          fullC: persisted.fullC,
          pendingApply: existing ? existing.pendingApply : false,
          identifying: existing ? existing.identifying : false,
          lastAppliedDuty: existing ? existing.lastAppliedDuty : undefined,
          lastAttemptAtMs: existing ? existing.lastAttemptAtMs : 0
        })
      }
    }
    cpuTemperaturePath = cpuPath
    fanZones = found
    // Prefer a currently-selected zone that still exists; else the first
    // connected zone; else just the first zone found.
    if (!found.some(function(z) { return z.key === selectedZoneKey })) {
      var connected = found.filter(function(z) { return !z.unplugged })
      var pool = connected.length > 0 ? connected : found
      selectedZoneKey = pool.length > 0 ? pool[0].key : ""
    }
    detecting = false
  }

  // ---------------------------------------------------------- sysfs shell

  // args: cpuTempPath, "cpu"|zoneKey label..., fields tab-separated. Reads
  // hwmon name once per chip so multiple pwm/fan pairs on the same
  // Super I/O chip (a very common board layout) don't re-open it per zone.
  readonly property string _detectScript: [
    "for d in /sys/class/hwmon/hwmon*; do",
    "  [ -r \"$d/name\" ] || continue",
    "  read -r name < \"$d/name\"",
    "  case \"$name\" in",
    "    coretemp|k10temp|zenpower|cpu_thermal)",
    "      for f in \"$d\"/temp*_input; do",
    "        [ -r \"$f\" ] || continue",
    "        printf 'cpu\\t%s\\n' \"$f\"; break",
    "      done ;;",
    "  esac",
    "  for pwm in \"$d\"/pwm[0-9]*; do",
    "    [ -f \"$pwm\" ] || continue",
    "    idx=${pwm##*/pwm}",
    "    case \"$idx\" in *[!0-9]*) continue ;; esac",
    "    enable_path=\"${pwm}_enable\"",
    "    fan_path=\"$d/fan${idx}_input\"",
    "    [ -r \"$fan_path\" ] || fan_path=\"\"",
    "    fault_path=\"$d/fan${idx}_fault\"",
    "    [ -r \"$fault_path\" ] || fault_path=\"\"",
    "    label=\"\"",
    "    label_path=\"$d/fan${idx}_label\"",
    "    [ -r \"$label_path\" ] && read -r label < \"$label_path\"",
    "    enable_val=\"\"",
    "    [ -r \"$enable_path\" ] && read -r enable_val < \"$enable_path\"",
    "    printf 'zone\\t%s-pwm%s\\t%s\\t%s\\t%s\\t%s\\t%s\\t%s\\n' \\",
    "      \"$name\" \"$idx\" \"$label\" \"$pwm\" \"$enable_path\" \"$fan_path\" \"$enable_val\" \"$fault_path\"",
    "  done",
    "done"
  ].join("\n")

  // args: cpuTempPath, zoneCount, then fanPath/pwmPath/faultPath triples.
  readonly property string _readScript: [
    "cpu_path=\"$1\"; shift",
    "count=\"$1\"; shift",
    "if [ -n \"$cpu_path\" ] && [ -r \"$cpu_path\" ]; then",
    "  read -r t < \"$cpu_path\"; printf 'cpu\\t%s\\n' \"$t\"",
    "fi",
    "i=0",
    "while [ \"$i\" -lt \"$count\" ]; do",
    "  fan_path=\"$1\"; pwm_path=\"$2\"; fault_path=\"$3\"; shift 3",
    "  rpm=\"\"; [ -n \"$fan_path\" ] && [ -r \"$fan_path\" ] && read -r rpm < \"$fan_path\"",
    "  duty=\"\"; [ -n \"$pwm_path\" ] && [ -r \"$pwm_path\" ] && read -r duty < \"$pwm_path\"",
    "  fault=\"\"; [ -n \"$fault_path\" ] && [ -r \"$fault_path\" ] && read -r fault < \"$fault_path\"",
    "  printf 'zone\\t%s\\t%s\\t%s\\n' \"$rpm\" \"$duty\" \"$fault\"",
    "  i=$((i+1))",
    "done"
  ].join("\n")

  // Defense in depth for both scripts below, which run as root via pkexec:
  // neither trusts a path argument just because the caller is this
  // plugin's own JS. Even though sysfs paths here always come from our own
  // enumeration (unprivileged users can't plant nodes under
  // /sys/class/hwmon — it's kernel-managed, not attacker-writable today),
  // a *privileged* script should independently re-verify it's staying
  // inside the tree it's meant for, refuse path traversal, and refuse a
  // symlinked target — sysfs attribute leaf files are always plain nodes,
  // so any of those failing means a bug upstream or the argument being
  // misused, not a normal fan-control write. `guard` returns 1 (never
  // exits — it's a predicate, called as `guard "$x" || exit 1`) the moment
  // any check fails, and 0 only once every check has actually passed.
  readonly property string _guardFunction: [
    "guard() {",
    "  case \"$1\" in",
    "    /sys/class/hwmon/hwmon*/*) : ;;",
    "    *) echo \"refusing: $1 is outside the sysfs hwmon tree\" >&2; return 1 ;;",
    "  esac",
    "  case \"$1\" in",
    "    *..*) echo \"refusing: $1 contains a path traversal segment\" >&2; return 1 ;;",
    "  esac",
    "  if [ -L \"$1\" ]; then",
    "    echo \"refusing: $1 is a symlink\" >&2; return 1",
    "  fi",
    "  return 0",
    "}"
  ].join("\n")

  // args: pwmPath, enablePath (may be empty), rawDuty(0-255).
  readonly property string _writeDutyScript: root._guardFunction + "\n" + [
    "pwm_path=\"$1\"; enable_path=\"$2\"; value=\"$3\"",
    "guard \"$pwm_path\" || exit 1",
    "if [ -n \"$enable_path\" ]; then",
    "  guard \"$enable_path\" || exit 1",
    "  printf '1' > \"$enable_path\" 2>/dev/null",
    "fi",
    "printf '%s' \"$value\" > \"$pwm_path\""
  ].join("\n")

  // args: path, value.
  readonly property string _writeValueScript: root._guardFunction + "\n" + [
    "path=\"$1\"; value=\"$2\"",
    "guard \"$path\" || exit 1",
    "printf '%s' \"$value\" > \"$path\""
  ].join("\n")

  // ----------------------------------------------------------- processes

  property Process detectProcess: Process {
    id: detectProcess
    command: [root._shBin, "-c", root._detectScript]
    stdout: StdioCollector { waitForEnd: true; onStreamFinished: root.applyDetection(text) }
    onExited: function(exitCode) { root.detecting = false }
  }

  property Process readProcess: Process {
    id: readProcess
    stdout: StdioCollector { waitForEnd: true; onStreamFinished: root.applyReadResults(text) }
  }

  // Serializes every privileged write (duty or enable-restore) one at a
  // time. `currentItem` carries the queued item across to onExited so the
  // completion handler knows which zone to reconcile and whether the write
  // actually succeeded.
  property Process writeProcess: Process {
    id: writeProcess
    property var currentItem: null
    running: false
    command: []
    onExited: function(exitCode) {
      var item = writeProcess.currentItem
      writeProcess.currentItem = null
      root._writeBusy = false
      if (item) {
        if (item.kind === "identify") {
          // Never set pendingApply — `identifying` alone gates the zone for
          // its whole pulse-then-revert lifecycle (see identifyZone).
          if (exitCode === 0) root._scheduleIdentifyRevert(item.zoneKey)
          else root._finishIdentify(item.zoneKey)
        } else {
          var patch = { pendingApply: false }
          if (exitCode === 0 && item.kind === "duty") patch.lastAppliedDuty = item.targetDuty
          root.replaceZone(item.zoneKey, patch)
        }
      }
      root.pumpWriteQueue()
    }
  }

  // Fires identifyDurationMs after a successful "identify" pulse write,
  // handing the zone back to its curve (or the board's own auto logic).
  property Timer identifyRevertTimer: Timer {
    id: identifyRevertTimer
    property string zoneKey: ""
    interval: root.identifyDurationMs
    repeat: false
    onTriggered: root._finishIdentify(zoneKey)
  }

  property Process sensorsDetectProcess: Process {
    id: sensorsDetectProcess
    running: false
    command: [root._pkexecBin, root._sensorsDetectBin, "--auto"]
    onExited: function(exitCode) {
      if (exitCode !== 0) {
        root.detecting = false
        root.detectError = "sensors-detect exited with status " + exitCode
        return
      }
      // Newly loaded modules need a beat to register their hwmon nodes.
      rescanAfterDetectTimer.restart()
    }
  }

  property Timer rescanAfterDetectTimer: Timer {
    id: rescanAfterDetectTimer
    interval: 1500
    repeat: false
    onTriggered: root.runDetection()
  }

  property FileView stateFile: FileView {
    id: stateFile
    path: root.configPath
    atomicWrites: true
    blockWrites: true
    printErrors: false
    onLoaded: {
      try {
        root._persisted = JSON.parse(text() || "{}")
      } catch (error) {
        root._persisted = { zones: {} }
      }
      root.stateReady = true
      root.runDetection()
    }
    onLoadFailed: function(error) {
      root._persisted = { zones: {} }
      root.stateReady = true
      root.runDetection()
    }
  }

  // Refuses to create/use the config directory if it's a symlink, before
  // and after the mkdir — a symlink planted there (by anything else able to
  // write under ~/.config before this ever runs) would otherwise make a
  // plain `mkdir -p` silently succeed and every later state.json write
  // follow it to wherever it points. Runs as the normal user (no pkexec —
  // this only ever touches this user's own config), so the worst case
  // without this guard is a same-user file redirected, not privilege
  // escalation, but it's the same class of fix as the pkexec write guards.
  readonly property string _ensureConfigDirScript: [
    "dir=\"$1\"",
    "if [ -L \"$dir\" ]; then",
    "  echo \"refusing: $dir is a symlink\" >&2; exit 1",
    "fi",
    root._mkdirBin + " -p -- \"$dir\"",
    "if [ -L \"$dir\" ]; then",
    "  echo \"refusing: $dir became a symlink\" >&2; exit 1",
    "fi"
  ].join("\n")

  property Process ensureConfigDirProcess: Process {
    running: true
    command: [root._shBin, "-c", root._ensureConfigDirScript, "sh", root.configDir]
    onExited: function(exitCode) { stateFile.reload() }
  }

  property Timer refreshTimer: Timer {
    interval: root.updateMs
    repeat: true
    running: root.stateReady
    triggeredOnStart: true
    onTriggered: root.refresh()
  }
}
