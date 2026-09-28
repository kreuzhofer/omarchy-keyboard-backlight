import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

BarWidget {
  id: root
  moduleName: "io.github.alexanderpuschkinberlin.keyboard-backlight"

  property int level: 0
  property int maximum: 2
  property string deviceName: ""
  property string lastSchedulePeriod: ""
  property bool sleeping: false
  property int chosenLevel: 0
  property bool lidOpen: true
  property int wakeTarget: -1
  property real wakeGuardUntil: 0
  readonly property string levelIcon: level <= 0 ? "󰹐" : (level >= maximum ? "󰛨" : "󰌶")
  readonly property bool scheduleEnabled: setting("scheduleEnabled", false) === true
  readonly property int nightStartHour: Number(setting("nightStartHour", 20))
  readonly property int dayStartHour: Number(setting("dayStartHour", 7))
  readonly property string helper: Qt.resolvedUrl("bin/keyboard-backlight").toString().replace(/^file:\/\//, "")
  readonly property bool opened: panelLoader.item ? panelLoader.item.opened === true : false

  function refresh() {
    if (!statusProc.running) statusProc.running = true
  }

  function setMode(mode) {
    if (actionProc.running) return
    chosenLevel = mode === "off" ? 0 : (mode === "low" ? 1 : maximum)
    actionProc.command = [root.helper, "set", mode]
    actionProc.running = true
  }

  function cycle() {
    if (level <= 0) setMode("low")
    else if (level >= maximum) setMode("off")
    else setMode("high")
  }

  function schedulePeriod() {
    var hour = new Date().getHours()
    var night = nightStartHour
    var day = dayStartHour
    if (night === day) return "night"
    if (night > day) return (hour >= night || hour < day) ? "night" : "day"
    return (hour >= night && hour < day) ? "night" : "day"
  }

  function applySchedule(force) {
    if (!scheduleEnabled) {
      lastSchedulePeriod = ""
      return
    }
    var period = schedulePeriod()
    if (!force && period === lastSchedulePeriod) return
    lastSchedulePeriod = period
    setMode(period === "night" ? "low" : "off")
  }

  function modeForLevel(value) {
    if (value <= 0) return "off"
    return value >= maximum ? "high" : "low"
  }

  // The firmware turns the keyboard light off when the lid closes and across
  // suspend. On wake or lid open, re-apply the schedule when it is enabled;
  // otherwise restore the last level the user chose.
  function handlePrepareForSleep(line) {
    if (line.indexOf("PrepareForSleep") < 0) return
    if (line.indexOf("true") >= 0) {
      resumeDelay.stop()
      sleeping = true
    } else if (sleeping) {
      resumeDelay.restart()
    }
  }

  function restoreAfterWake() {
    sleeping = false
    var mode
    if (scheduleEnabled) {
      lastSchedulePeriod = schedulePeriod()
      mode = lastSchedulePeriod === "night" ? "low" : "off"
      console.log("keyboard-backlight: wake, applying schedule (" + mode + ")")
    } else {
      mode = modeForLevel(chosenLevel)
      console.log("keyboard-backlight: wake, restoring " + mode)
    }
    // The firmware can still reset the light a few seconds after resume, so
    // keep enforcing the target for a short window instead of setting it once.
    wakeTarget = mode === "off" ? 0 : (mode === "low" ? 1 : maximum)
    wakeGuardUntil = Date.now() + 30000
    setMode(mode)
    wakeGuard.restart()
  }

  function enforceWakeTarget() {
    if (wakeTarget < 0 || sleeping) return
    if (Date.now() > wakeGuardUntil) { wakeTarget = -1; return }
    if (level !== wakeTarget && !actionProc.running) {
      console.log("keyboard-backlight: level " + level + " drifted after wake, re-applying " + wakeTarget)
      setMode(modeForLevel(wakeTarget))
    }
  }

  function persistSettings(values) {
    var entry = { id: root.moduleName }
    for (var existing in root.settings) if (existing !== "id") entry[existing] = root.settings[existing]
    for (var key in values) entry[key] = values[key]
    root.settings = entry
    if (root.bar && root.bar.shell && typeof root.bar.shell.updateEntryInline === "function")
      root.bar.shell.updateEntryInline(root.moduleName, entry)
  }

  function setScheduleEnabled(value) {
    persistSettings({ scheduleEnabled: value })
    lastSchedulePeriod = ""
    if (value) Qt.callLater(function() { root.applySchedule(true) })
  }

  function setScheduleHour(key, value) {
    var normalized = ((Number(value) % 24) + 24) % 24
    var update = {}
    update[key] = normalized
    persistSettings(update)
    lastSchedulePeriod = ""
    if (scheduleEnabled) Qt.callLater(function() { root.applySchedule(true) })
  }

  function open() { if (panelLoader.item) panelLoader.item.open() }
  function close() { if (panelLoader.item) panelLoader.item.close() }
  function toggle() { if (panelLoader.item) panelLoader.item.toggle() }
  readonly property bool popoutSwitchClosing: panelLoader.item ? panelLoader.item.popoutSwitchClosing === true : false
  function closeForPopoutSwitch() { if (panelLoader.item) panelLoader.item.closeForPopoutSwitch() }

  function injectPanel() {
    var target = panelLoader.item
    if (!target) return
    target.bar = root.bar
    target.anchorItem = button
    target.hostWidget = root
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight
  onBarChanged: injectPanel()
  onScheduleEnabledChanged: if (!scheduleEnabled) lastSchedulePeriod = ""
  Component.onCompleted: {
    refresh()
    scheduleDelay.start()
  }

  Loader {
    id: panelLoader
    active: true
    source: Qt.resolvedUrl("Panel.qml")
    visible: false
    onLoaded: { root.injectPanel(); Qt.callLater(root.injectPanel) }
  }

  Timer { interval: 5000; running: true; repeat: true; onTriggered: { if (!root.sleeping) { root.applySchedule(false); root.refresh() } } }
  Timer { id: resumeDelay; interval: 2000; repeat: false; onTriggered: root.restoreAfterWake() }
  Timer { id: wakeGuard; interval: 1000; repeat: true; running: root.wakeTarget >= 0; onTriggered: root.refresh() }
  Timer { id: scheduleDelay; interval: 1000; repeat: false; onTriggered: root.applySchedule(true) }

  Process {
    id: statusProc
    command: [root.helper, "status"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var values = text.trim().split(/\s+/)
        if (values.length >= 4) {
          var wasOpen = root.lidOpen
          root.level = Number(values[0]) || 0
          root.maximum = Number(values[1]) || 2
          root.lidOpen = values[2] !== "closed"
          root.deviceName = values.slice(3).join(" ")
          if (root.sleeping) return
          if (!root.lidOpen) { root.wakeTarget = -1; return }
          if (!wasOpen) resumeDelay.restart()
          else if (root.wakeTarget >= 0) root.enforceWakeTarget()
          // A zero read may be the firmware, so only non-zero reads (Fn+Space) count
          else if (!resumeDelay.running && root.level > 0) root.chosenLevel = root.level
        }
      }
    }
  }

  Process {
    id: sleepMonitor
    running: true
    command: ["gdbus", "monitor", "--system", "--dest", "org.freedesktop.login1", "--object-path", "/org/freedesktop/login1"]
    stdout: SplitParser { onRead: function(line) { root.handlePrepareForSleep(line) } }
    onExited: sleepMonitorRestart.start()
  }
  Timer { id: sleepMonitorRestart; interval: 5000; repeat: false; onTriggered: sleepMonitor.running = true }

  Process { id: actionProc; onExited: refreshDelay.start() }
  Timer { id: refreshDelay; interval: 150; repeat: false; onTriggered: root.refresh() }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: root.levelIcon
    active: root.level > 0
    tooltipText: ""
    onPressed: function(b) {
      if (b === Qt.RightButton) root.cycle()
      else root.toggle()
    }
  }
}
