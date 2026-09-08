// Pure helpers shared by Service.qml and Panel.qml. No Quickshell imports
// here so this file can also run under plain Node for tests.

var MIN_DUTY = 25   // fan never fully stops — keeps bearings lubricated and
                     // avoids a thermal-runaway blind spot if the sensor lags
var RAMP_DUTY = 60
var FULL_DUTY = 100

var TEMP_MIN = 30
var TEMP_MAX = 95

var HISTORY_LENGTH = 90 // ~3 minutes at a 2s poll interval

function clampTemp(value, fallback) {
  var n = Number(value)
  if (!isFinite(n)) return fallback
  return Math.max(TEMP_MIN, Math.min(TEMP_MAX, Math.round(n)))
}

function clampDuty(value) {
  var n = Number(value)
  if (!isFinite(n)) return MIN_DUTY
  return Math.max(0, Math.min(100, Math.round(n)))
}

function formatTemp(celsius) {
  if (!isFinite(celsius) || celsius <= 0) return "--°C"
  return Math.round(celsius) + "°C"
}

function formatRpm(rpm) {
  if (!isFinite(rpm) || rpm < 0) return "-- RPM"
  return Math.round(rpm).toLocaleString() + " RPM"
}

function formatDuty(percent) {
  if (!isFinite(percent) || percent < 0) return "--%"
  return Math.round(percent) + "%"
}

// Fan curve: flat MIN_DUTY at/under quietC, linear MIN_DUTY -> RAMP_DUTY
// between quietC and rampC, linear RAMP_DUTY -> FULL_DUTY between rampC and
// fullC, flat FULL_DUTY at/over fullC.
function dutyForTemperature(tempC, thresholds) {
  var t = Number(tempC)
  if (!isFinite(t)) return MIN_DUTY
  var quiet = thresholds.quietC
  var ramp = thresholds.rampC
  var full = thresholds.fullC

  if (t <= quiet) return MIN_DUTY
  if (t >= full) return FULL_DUTY
  if (t <= ramp) {
    var span1 = Math.max(1, ramp - quiet)
    return MIN_DUTY + (RAMP_DUTY - MIN_DUTY) * ((t - quiet) / span1)
  }
  var span2 = Math.max(1, full - ramp)
  return RAMP_DUTY + (FULL_DUTY - RAMP_DUTY) * ((t - ramp) / span2)
}

// Thresholds always keep quiet < ramp < full, each clamped to
// [TEMP_MIN, TEMP_MAX]. Mirrors the screensaver/lock/suspend floor-pushing
// pattern: moving one slider past a neighbor pushes that neighbor up too.
function normalizeThresholds(thresholds) {
  var quiet = clampTemp(thresholds && thresholds.quietC, 45)
  var ramp = clampTemp(thresholds && thresholds.rampC, 65)
  var full = clampTemp(thresholds && thresholds.fullC, 80)
  if (ramp <= quiet) ramp = Math.min(TEMP_MAX, quiet + 1)
  if (full <= ramp) full = Math.min(TEMP_MAX, ramp + 1)
  return { quietC: quiet, rampC: ramp, fullC: full }
}

function setQuiet(thresholds, value) {
  var next = normalizeThresholds(thresholds)
  next.quietC = clampTemp(value, next.quietC)
  return normalizeThresholds(next)
}

function setRamp(thresholds, value) {
  var next = normalizeThresholds(thresholds)
  next.rampC = clampTemp(value, next.rampC)
  if (next.rampC <= next.quietC) next.rampC = Math.min(TEMP_MAX, next.quietC + 1)
  return normalizeThresholds(next)
}

function setFull(thresholds, value) {
  var next = normalizeThresholds(thresholds)
  next.fullC = clampTemp(value, next.fullC)
  if (next.fullC <= next.rampC) next.fullC = Math.min(TEMP_MAX, next.rampC + 1)
  return normalizeThresholds(next)
}

function pushHistory(history, sample) {
  var next = history ? history.slice() : []
  next.push(sample)
  if (next.length > HISTORY_LENGTH) next.splice(0, next.length - HISTORY_LENGTH)
  return next
}

// Percent 0-100 -> raw pwm byte value (Linux hwmon pwm files are 0-255).
function dutyToRaw(percent) {
  return Math.max(0, Math.min(255, Math.round(clampDuty(percent) * 255 / 100)))
}

function rawToDuty(raw) {
  var n = Number(raw)
  if (!isFinite(n)) return 0
  return Math.max(0, Math.min(100, Math.round(n * 100 / 255)))
}

// A pwm header with nothing plugged into it still exists in sysfs, so
// detection alone can't tell it apart from a real fan — only driving it and
// watching for RPM can. `fault` is the chip's own fanN_fault flag when the
// driver exposes one (authoritative, no need to wait for it). Otherwise: a
// fan driven at a real spin-up duty that still reports 0 RPM for several
// consecutive polls in a row is almost certainly not connected. A single
// zero reading isn't enough (startup lag, a transient misread), so it takes
// a streak — and any nonzero RPM, or the fault flag clearing, resets the
// streak and un-flags it immediately, since that's proof it's alive.
var UNPLUGGED_STREAK_THRESHOLD = 3
var UNPLUGGED_MIN_DUTY = 40

function nextUnpluggedState(state, sample) {
  var streak = (state && state.streak) || 0
  if (sample.fault === true) return { unplugged: true, streak: streak }
  if (sample.rpm > 0) return { unplugged: false, streak: 0 }
  if (sample.rpm === 0 && sample.duty >= UNPLUGGED_MIN_DUTY) {
    streak += 1
    return { unplugged: streak >= UNPLUGGED_STREAK_THRESHOLD, streak: streak }
  }
  // rpm unknown (-1), or duty too low to expect a real fan to be spinning
  // yet — inconclusive, so hold whatever was last known.
  return { unplugged: !!(state && state.unplugged), streak: streak }
}

if (typeof module !== "undefined") {
  module.exports = {
    MIN_DUTY: MIN_DUTY,
    RAMP_DUTY: RAMP_DUTY,
    FULL_DUTY: FULL_DUTY,
    TEMP_MIN: TEMP_MIN,
    TEMP_MAX: TEMP_MAX,
    HISTORY_LENGTH: HISTORY_LENGTH,
    clampTemp: clampTemp,
    clampDuty: clampDuty,
    formatTemp: formatTemp,
    formatRpm: formatRpm,
    formatDuty: formatDuty,
    dutyForTemperature: dutyForTemperature,
    normalizeThresholds: normalizeThresholds,
    setQuiet: setQuiet,
    setRamp: setRamp,
    setFull: setFull,
    pushHistory: pushHistory,
    dutyToRaw: dutyToRaw,
    rawToDuty: rawToDuty,
    UNPLUGGED_STREAK_THRESHOLD: UNPLUGGED_STREAK_THRESHOLD,
    UNPLUGGED_MIN_DUTY: UNPLUGGED_MIN_DUTY,
    nextUnpluggedState: nextUnpluggedState
  }
}
