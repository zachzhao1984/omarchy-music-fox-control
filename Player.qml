// musicfox process control and key injection.
//
// MPRIS covers transport, seeking and volume, but a few things only the TUI can
// do:
//
//   * changing the play mode — LoopStatus/Shuffle are accepted over MPRIS, read
//     back changed, and then ignored (the footer stays [顺序播放], playback is
//     unaffected). The real control is the `p` key.
//   * starting from a cold queue — Next/Previous on an unstarted player walk
//     the queue but never open an audio stream.
//   * picking a track from the queue.
//
// All of those are keystrokes, so the plugin keeps the player in a tmux session
// and types into it. That is also how it starts the player at all: musicfox is
// a bubbletea TUI that dies with "could not open TTY" when spawned without a
// terminal, and a detached tmux session hands it a TTY without stealing focus.
//
// The session name is only a default. Players are discovered by
// `pane_current_command`, so a musicfox the user started in their own tmux is
// adopted and driven just as well.
import QtQuick
import Quickshell
import Quickshell.Io

Item {
  id: root

  property string sessionName: "musicfox"
  property string binary: "musicfox"
  property string subcommand: "netease"

  // tmux pane identifiers ("session:pane") whose foreground process is musicfox.
  property var targets: []
  property bool launchPending: false

  // Bumped whenever we type something, so dependent views can re-poll state
  // that only the TUI knows (the play-mode footer, the queue cursor).
  property int interactionTick: 0
  property string lastError: ""

  readonly property bool available: targets.length > 0
  readonly property string target: targets.length > 0 ? String(targets[0]) : ""
  readonly property string pluginDir: String(Qt.resolvedUrl("."))
    .replace(/^file:\/\//, "").replace(/\/$/, "")

  signal playersChanged()

  // ----------------------------------------------------------- shell runner
  //
  // One bash at a time. tmux is fast, and serialising keeps keystrokes in the
  // order the user pressed them even when they arrive in the same frame.

  property var _queue: []
  property bool _busy: false

  function shellQuote(value) {
    return "'" + String(value).replace(/'/g, "'\\''") + "'"
  }

  function join(argv) {
    var parts = []
    for (var i = 0; i < argv.length; i++) parts.push(shellQuote(argv[i]))
    return parts.join(" ")
  }

  function run(argv, onDone) {
    _queue.push({ script: join(argv), done: onDone || null })
    pump()
  }

  function pump() {
    if (_busy) return
    if (_queue.length === 0) return
    var job = _queue.shift()
    _busy = true
    runner.job = job
    runner.command = ["bash", "-lc", job.script]
    runner.running = true
  }

  Process {
    id: runner
    property var job: null
    property string output: ""
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: runner.output = this.text || ""
    }
    onStarted: output = ""
    onExited: function(exitCode, exitStatus) {
      var finished = runner.job
      runner.job = null
      root._busy = false
      var text = runner.output
      if (finished && finished.done) finished.done(exitCode, text)
      if (exitCode !== 0 && text) root.lastError = String(text).slice(0, 200)
      Qt.callLater(root.pump)
    }
  }

  // ------------------------------------------------------------- discovery

  function refresh() {
    if (discover.running) return
    discover.running = true
  }

  Process {
    id: discover
    command: ["bash", "-lc",
      "tmux list-panes -a -F '#{session_name}:#{pane_index}\t#{pane_current_command}' 2>/dev/null"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var lines = String(this.text || "").split("\n")
        var next = []
        for (var i = 0; i < lines.length; i++) {
          var line = lines[i]
          if (!line) continue
          var tab = line.indexOf("\t")
          if (tab < 0) continue
          if (line.slice(tab + 1).replace(/\s+$/, "") !== "musicfox") continue
          next.push(line.slice(0, tab))
        }
        if (next.join("|") !== root.targets.join("|")) {
          root.targets = next
          root.playersChanged()
        }
        // Keep polling while the player is missing so a terminal the user opens
        // themselves is picked up without a manual refresh.
        watchPoll.interval = next.length > 0 ? 4000 : 2500
        watchPoll.restart()
      }
    }
    onExited: if (root.targets.length === 0) watchPoll.restart()
  }

  Timer {
    id: watchPoll
    interval: 2500
    repeat: false
    onTriggered: root.refresh()
  }

  Component.onCompleted: refresh()

  // ------------------------------------------------------------- lifecycle

  function launch() {
    if (launchPending) return
    launchPending = true
    // -d detaches, so the bar is not stolen by a terminal. -x/-y keep the TUI
    // wide enough for musicfox's double-column layout.
    var argv = ["tmux", "new-session", "-d", "-s", sessionName,
                "-x", "140", "-y", "45",
                binary + " " + subcommand]
    run(argv, function() {
      launchPending = false
      settle.attempts = 0
      settle.restart()
    })
  }

  Timer {
    id: settle
    property int attempts: 0
    interval: 1200
    repeat: false
    onTriggered: {
      attempts += 1
      root.refresh()
      if (root.available || attempts >= 12) return
      restart()
    }
  }

  // Ask musicfox to quit the way its own binding does (q), then drop the
  // session if it is still around. Quitting through the TUI rather than
  // killing the pane lets it flush the queue snapshot to disk.
  function stop() {
    if (!available) return
    var session = target.split(":")[0]
    sendLiteral("q")
    var poll = 0
    var finish = function() {
      poll += 1
      root.run(["tmux", "list-sessions", "-F", "#{session_name}"], function(code, text) {
        var alive = String(text || "").split("\n").indexOf(session) !== -1
        if (!alive || poll > 6) {
          if (alive) root.run(["tmux", "kill-session", "-t", session], function() { root.refresh() })
          else root.refresh()
          return
        }
        Qt.callLater(finish)
      })
    }
    finish()
  }

  // Bring the player's TUI on screen.
  //
  // NOT `tmux switch-client`: our session is detached, so there is no attached
  // client to switch and tmux answers "no current client" — the command exits
  // non-zero and nothing visible happens. The session has to be attached to a
  // terminal, which means opening one. scripts/mf-attach.sh does that and
  // refuses to open a second view of an already-attached session.
  function focusPlayer() {
    if (!available) return
    var session = target.split(":")[0]
    Quickshell.execDetached([
      "omarchy-launch-tui",
      "--app-id=org.omarchy.musicfox",
      pluginDir + "/scripts/mf-attach.sh", session
    ])
  }

  // ------------------------------------------------------------ key input

  function sendLiteral(text) {
    if (!available) return false
    var pane = target
    run(["tmux", "send-keys", "-l", "-t", pane, text], function() {
      root.interactionTick += 1
    })
    return true
  }

  // Named keys (space, Enter, arrows) have to go through tmux's key table
  // rather than -l, or tmux would type the literal word.
  function sendKey(name) {
    if (!available) return false
    var pane = target
    run(["tmux", "send-keys", "-t", pane, name], function() {
      root.interactionTick += 1
    })
    return true
  }

  // musicfox's own bindings, from [keybindings.app] in config.toml.
  readonly property string keyModeNext: "p"
  readonly property string keyModePrevious: "P"
  readonly property string keyToggle: "space"
  readonly property string keyNext: "]"
  readonly property string keyPrevious: "["
  readonly property string keyVolumeDown: "-"
  readonly property string keyVolumeUp: "="
  readonly property string keySeekBack5: "X"
  readonly property string keySeekBack1: "x"
  readonly property string keySeekForward5: "v"
  readonly property string keySeekForward10: "V"
  readonly property string keyLike: "z"

  function cyclePlayMode(backwards) {
    return sendLiteral(backwards ? keyModePrevious : keyModeNext)
  }

  function togglePlaying() { return sendKey(keyToggle) }
  function nextTrack() { return sendLiteral(keyNext) }
  function previousTrack() { return sendLiteral(keyPrevious) }
  function volumeUp() { return sendLiteral(keyVolumeUp) }
  function volumeDown() { return sendLiteral(keyVolumeDown) }
  function seekForward(fiveSeconds) { return sendLiteral(fiveSeconds ? keySeekForward5 : keySeekForward10) }
  function seekBackward(fiveSeconds) { return sendLiteral(fiveSeconds ? keySeekBack5 : keySeekBack1) }
}
