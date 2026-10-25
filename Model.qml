// Everything the plugin knows about musicfox: the MPRIS player, the parsed
// lyric, the persisted queue, and the guard rails that work around how
// musicfox behaves over MPRIS.
//
// Measured behaviour this file encodes (musicfox 5.1.0, player.engine = "mpv"):
//
//   * Play/Pause/PlayPause/Next/Previous/Seek/Volume all work, positions are
//     real, and Quickshell reports them in SECONDS. Nothing crashes: the beep
//     engine's nil-timer panic is mpv-prefixed, which is why this plugin
//     documents mpv as a requirement.
//   * LoopStatus and Shuffle are write-accepted and read-back-changed but have
//     NO effect on playback. Play mode must be cycled with the `p` key.
//   * `HasTrackList` is true but /PlayList does not exist. The queue has to be
//     read out of musicfox's bbolt file (scripts/queue.py).
//   * Cold start: without autoplay the player sits at Stopped with an empty
//     metadata map. Play() from there normally starts playback, but when the
//     persisted queue's first track is unplayable the player reports Playing
//     with position pinned at 0 and mpv still idle. That is indistinguishable
//     from a stall, so we detect "position frozen at 0 while claiming Playing"
//     and recover with Next() instead of telling the user it is playing.
import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Services.Mpris
import "Lyrics.js" as Lyrics

Item {
  id: root

  property var shell: null
  property var player: null

  // Seconds. A stall is "claims Playing, position has not moved" for this long.
  readonly property int queuePollMs: 8000

  // ------------------------------------------------------------ MPRIS side

  // musicfox registers org.mpris.MediaPlayer2.musicfox.instance<pid>, where the
  // pid is the *child* it forks, so matching on the bus name is useless across
  // restarts. Identity is the stable part.
  //
  // Identity is also the ONLY safe match: DBus leaves a name behind after its
  // owner dies, and Quickshell still lists it (we observed a stale
  // org.mpris.MediaPlayer2.mpv.instance with no owner serving garbage). Matching
  // on dbusName would happily bind to such a corpse.
  readonly property var machine: {
    var list = (Mpris.players && Mpris.players.values) || []
    for (var i = 0; i < list.length; i++) {
      var candidate = list[i]
      if (candidate && isMusicfox(candidate)) return candidate
    }
    return null
  }

  function isMusicfox(candidate) {
    if (!candidate) return false
    return String(candidate.identity || "").toLowerCase().indexOf("musicfox") !== -1
  }

  readonly property bool running: machine !== null
  readonly property bool isPlaying: machine ? !!machine.isPlaying : false
  readonly property int playbackState: machine ? machine.playbackState : 0
  readonly property string trackTitle: machine ? String(machine.trackTitle || "") : ""
  readonly property string trackArtist: machine ? String(machine.trackArtist || "") : ""
  readonly property string trackAlbum: machine ? String(machine.trackAlbum || "") : ""
  readonly property string trackArtUrl: machine ? String(machine.trackArtUrl || "") : ""
  readonly property real length: machine ? Math.max(0, Number(machine.length) || 0) : 0
  readonly property bool canSeek: machine ? !!machine.canSeek : false
  readonly property bool canGoNext: machine ? !!machine.canGoNext : false
  readonly property bool canGoPrevious: machine ? !!machine.canGoPrevious : false
  readonly property double volume: machine ? Number(machine.volume) || 0 : 0
  readonly property bool volumeSupported: machine ? !!machine.volumeSupported : false

  readonly property bool hasTrack: trackTitle !== "" || trackArtist !== ""

  // Position. Quickshell exposes `MprisPlayer.position` as a plain getter that
  // issues a synchronous DBus read returning SECONDS, and — measured against
  // Quickshell 0.3.2 — it never emits positionChanged. Binding to it yields a
  // frozen zero, so this is polled. Everything else on MprisPlayer is a real
  // notifying property; only position needs this.
  property double rawPosition: 0
  readonly property double position: rawPosition

  readonly property real progress: length > 0 ? Math.min(1, Math.max(0, position / length)) : 0

  onMachineChanged: {
    rawPosition = machine ? Number(machine.position) || 0 : 0
    lyricLines = []
    _lastLyricRaw = ""
    refreshArt()
    stallSampleAt = 0
    stalled = false
    updateLyric()
  }

  // 800 ms: fine enough that the lyric highlight lands on the right line, slow
  // enough that a paused player costs nothing (the timer stops).
  Timer {
    id: positionPoll
    interval: 800
    repeat: true
    running: root.running && root.isPlaying
    onTriggered: root.samplePosition()
  }

  // Sample once even when stopped, so the bar/panel show a paused track's true
  // position rather than the value from the last time it was playing.
  function samplePosition() {
    if (!machine) return
    var next = Number(machine.position) || 0
    if (Math.abs(next - rawPosition) >= 0.05) rawPosition = next
  }

  Connections {
    target: root.machine
    ignoreUnknownSignals: true
    function onIsPlayingChanged() {
      if (root.isPlaying) root.samplePosition()
      else root.stalled = false
    }
  }

  // ---------------------------------------------------------- stall guard
  //
  // "Playing with position frozen" is how an unplayable track manifests: the
  // player reports Playing, the length is known, and the position never leaves
  // 0. Left alone the UI would show a pause button and a bar that never fills.
  //
  // The test is a delta, not an absolute value — position legitimately sits at
  // 0 for the first second of a good track, so "position is small" would fire
  // on every normal start.

  property bool stalled: false
  property double stallSamplePosition: 0
  property double stallSampleAt: 0
  property string stallTrackKey: ""

  readonly property string trackSignature: {
    if (!machine) return ""
    return trackTitle + "\u0000" + trackArtist + "\u0000" + String(length)
  }

  onTrackSignatureChanged: {
    // A new track gets a clean slate; the old verdict does not carry over.
    stalled = false
    stallSampleAt = 0
    stallSamplePosition = position
    stallTrackKey = trackSignature
  }

  Timer {
    id: stallWatch
    interval: 1500
    repeat: true
    running: root.running && root.isPlaying
    onTriggered: root.detectStall()
  }

  function detectStall() {
    if (!machine || !isPlaying || length <= 0) {
      stalled = false
      stallSampleAt = 0
      return
    }

    // Use the freshly read MPRIS position, not the polled copy: the verdict
    // must not lag a second behind reality.
    var now = Date.now() / 1000
    var current = Number(machine.position) || 0

    if (stallSampleAt === 0) {
      stallSampleAt = now
      stallSamplePosition = current
      return
    }

    if (now - stallSampleAt < 1.2) return

    var advanced = current - stallSamplePosition
    stallSampleAt = now
    stallSamplePosition = current

    if (advanced > 0.05) {
      stalled = false
      return
    }

    stalled = true

    // Skip forward once per track. If Next also lands on a silent track the
    // guard stops trying rather than racing through the whole queue.
    if (stallTrackKey !== trackSignature) {
      stallTrackKey = trackSignature
      if (machine.canGoNext) machine.next()
    }
  }

  // ------------------------------------------------------------- transport
  //
  // Cold start is the one case where MPRIS alone is wrong. `Play()` on a player
  // with nothing loaded flips PlaybackStatus to Playing, publishes the next
  // track's metadata, and never opens an audio stream — and once it is in that
  // state it stays there (Next keeps swapping metadata without ever producing
  // audio). The TUI's own space key takes musicfox's real start-playback path,
  // so a cold start types space and everything after that goes over MPRIS.
  //
  // Warming up first and then letting MPRIS take over is also why a single
  // click is enough: the player is only cold when there is no track at all.

  readonly property bool coldStart: machine !== null && !hasTrack

  function play() {
    if (!machine) return
    if (coldStart) {
      // Fall back to MPRIS only when no TUI is reachable to press space in.
      if (player && player.available) {
        player.togglePlaying()
        return
      }
      if (machine.canPlay) machine.play()
      return
    }
    if (machine.canPlay) machine.play()
    else if (machine.canTogglePlaying) machine.togglePlaying()
  }

  function pause() {
    if (!machine) return
    if (machine.canPause) machine.pause()
    else if (machine.canTogglePlaying && isPlaying) machine.togglePlaying()
  }

  function togglePlaying() {
    if (!machine) return
    if (coldStart) {
      if (player && player.available) player.togglePlaying()
      else if (machine.canTogglePlaying) machine.togglePlaying()
      return
    }
    if (isPlaying) pause()
    else play()
  }

  function next() {
    if (!machine) return
    if (machine.canGoNext) machine.next()
  }

  function previous() {
    if (!machine) return
    if (machine.canGoPrevious) machine.previous()
  }

  // Seeking is a plain offset in seconds; Quickshell maps it to MPRIS Seek,
  // which takes microseconds. Writing `position` maps to SetPosition.
  function seekTo(seconds) {
    if (!machine || length <= 0) return
    var clamped = Math.min(Math.max(0, seconds), Math.max(0, length - 0.5))
    machine.position = clamped
  }

  function seekBy(delta) {
    if (!machine) return
    if (machine.canSeek) machine.seek(delta)
  }

  function setVolume(value) {
    if (!machine || !volumeSupported) return
    machine.volume = Math.min(1, Math.max(0, value))
  }

  // LoopStatus/Shuffle are decorative over MPRIS, so the real control is the
  // TUI key. We still mirror what we know into `playMode` for display.
  function cyclePlayMode(backwards) {
    if (!player) return
    if (player.available) player.cyclePlayMode(backwards)
    else if (machine) machine.loopState = (machine.loopState + 1) % 3
    modePoll.restart()
  }

  // -------------------------------------------------------- play mode label
  //
  // musicfox writes the mode into its footer ("[顺序播放]"). LoopStatus cannot
  // be trusted (it lies), so we scrape it. Cheap enough at this interval and
  // only while the panel or bar actually shows it.

  property string playMode: ""
  property bool readPlayMode: false

  // 单曲循环 in musicfox's own vocabulary. Exposed so the panel can show a
  // toggle whose state is read back from the player, not from a wish.
  readonly property string singleLoopMode: "单曲循环"
  readonly property bool singleLoop: playMode === singleLoopMode

  // The poll timer's `running` follows this flag on its own; no manual
  // restart() here. A restart() on a repeat:true timer interrupts the interval
  // it was already on and can start it at a moment when the player is still
  // undiscovered.
  onReadPlayModeChanged: if (readPlayMode) sampleMode()

  // Drive the player to a specific mode.
  //
  // MPRIS LoopStatus is write-accepted and read-back-changed but has no effect
  // on playback, so the mode has to be cycled with the `p` key until the
  // footer reads what we want. The cycle order is fixed (measured):
  //   列表循环 → 顺序播放 → 单曲循环 → 列表随机 → 无限随机 → 列表循环
  // so the worst case is five presses. Each press is followed by a footer read
  // before deciding again, because pressing blind would overshoot.
  property int modeTarget: 0
  property int modeAttempts: 0

  function setSingleLoop(enabled) {
    if (!player || !player.available) return
    if (enabled === singleLoop) return
    modeTarget = enabled ? 1 : 0
    modeAttempts = 0
    modeStep()
  }

  function toggleSingleLoop() {
    setSingleLoop(!singleLoop)
  }

  function modeStep() {
    if (modeAttempts >= 6) return
    if (!player || !player.available) return

    // Nothing sampled yet: read the footer once and come back through modeWait,
    // so the first decision is made against reality rather than a guess. This
    // does not consume an attempt.
    if (playMode === "") {
      sampleMode()
      modeWait.restart()
      return
    }

    modeAttempts += 1
    if (singleLoop === (modeTarget === 1)) return
    player.cyclePlayMode(false)
    modeWait.restart()
  }

  // Let the TUI repaint its footer after a keypress, then re-read. 220 ms is
  // comfortably more than one frame at the default frameRate (5 fps).
  Timer {
    id: modeWait
    interval: 220
    repeat: false
    onTriggered: root.sampleModeAndContinue()
  }

  function sampleModeAndContinue() {
    if (!player || !player.available) return
    player.run(["tmux", "capture-pane", "-p", "-t", player.target], function(code, text) {
      if (code !== 0) return
      var found = parseMode(text)
      if (found !== "") root.playMode = found
      root.modeStep()
    })
  }

  Timer {
    id: modePoll
    interval: 1500
    // repeat, not one-shot: Player.targets is filled by an async tmux poll, so
    // the player is briefly unavailable while the panel is already open. A
    // one-shot timer whose `running` binding is false at that moment never
    // fires again, and the mode would stay blank until the panel was reopened.
    repeat: true
    running: root.running && root.readPlayMode
    onTriggered: root.sampleMode()
  }

  function sampleMode() {
    if (!player || !player.available) return
    player.run(["tmux", "capture-pane", "-p", "-t", player.target], function(code, text) {
      if (code !== 0) return
      var found = parseMode(text)
      if (found !== root.playMode) root.playMode = found
    })
  }

  readonly property var modeNames: [
    "列表循环", "顺序播放", "单曲循环", "列表随机", "无限随机", "心动模式", "未知模式"
  ]

  function parseMode(text) {
    var haystack = String(text || "")
    for (var i = 0; i < modeNames.length; i++) {
      if (haystack.indexOf("[" + modeNames[i] + "]") !== -1) return modeNames[i]
    }
    return ""
  }

  // ----------------------------------------------------------------- lyrics
  //
  // musicfox puts the entire timed lyric, translations included, into
  // xesam:asText. That is why the lyric is free: no second request, no API.

  property var lyricLines: []
  property string _lastLyricRaw: ""
  property int lyricIndex: -1
  readonly property string currentLyric: {
    if (lyricIndex < 0 || lyricIndex >= lyricLines.length) return ""
    return String(lyricLines[lyricIndex].text || "")
  }
  readonly property string currentLyricTranslation: {
    if (lyricIndex < 0 || lyricIndex >= lyricLines.length) return ""
    return String(lyricLines[lyricIndex].translation || "")
  }

  readonly property string metadataLyric: {
    if (!machine) return ""
    var meta = machine.metadata
    if (!meta) return ""
    var text = meta["xesam:asText"]
    return typeof text === "string" ? text : ""
  }

  onMetadataLyricChanged: updateLyric()
  onRawPositionChanged: updateLyricIndex()

  function updateLyric() {
    var raw = metadataLyric
    if (raw === _lastLyricRaw) { updateLyricIndex(); return }
    _lastLyricRaw = raw
    var parsed = Lyrics.parse(raw)
    lyricLines = parsed
    updateLyricIndex()
  }

  function updateLyricIndex() {
    var index = Lyrics.indexAt(lyricLines, position)
    if (index !== lyricIndex) lyricIndex = index
  }

  // ---------------------------------------------------------------- queue

  property var queue: ({ ok: false, tracks: [], current: -1 })
  property bool queueLoaded: false
  readonly property int queueLength: queue && queue.tracks ? queue.tracks.length : 0
  readonly property int queueIndex: queue && queue.current !== undefined ? queue.current : -1
  readonly property string queueTrackName: trackInQueue() ? String(trackInQueue().name || "") : ""
  readonly property string queueTrackArtist: trackInQueue() ? String(trackInQueue().artist || "") : ""
  readonly property bool loggedIn: queue ? !!queue.loggedIn : false
  readonly property string nickname: queue ? String(queue.nickname || "") : ""
  readonly property string avatarUrl: queue ? String(queue.avatarUrl || "") : ""

  function trackInQueue() {
    if (!queue || !queue.tracks) return null
    if (queueIndex < 0 || queueIndex >= queue.tracks.length) return null
    return queue.tracks[queueIndex]
  }

  // The panel shows the current track plus a few that follow it, so the list
  // reads like a queue rather than a table of contents.
  // Current track plus what follows it. Rows now carry album covers, so the
  // list is taller per entry; six keeps the whole panel within a 1080p screen
  // without the queue crowding out the lyric above it.
  readonly property int upcomingTrackLimit: 6
  readonly property var upcomingTracks: {
    var out = []
    if (!queue || !queue.tracks) return out
    var start = Math.max(0, queueIndex)
    for (var i = start; i < queue.tracks.length && out.length < upcomingTrackLimit; i++)
      out.push(queue.tracks[i])
    return out
  }

  readonly property string dbPath: {
    var root = Quickshell.env("MUSICFOX_ROOT")
    if (root) return root + "/db/musicfox.db"
    var dataHome = Quickshell.env("XDG_DATA_HOME")
      || (Quickshell.env("HOME") + "/.local/share")
    return dataHome + "/go-musicfox/db/musicfox.db"
  }

  readonly property string queueScript: pluginScript("scripts/queue.py")

  function pluginScript(relative) {
    return pluginRoot + "/" + relative
  }

  // The plugin's own directory, resolved once. `Qt.resolvedUrl(".")` is the
  // only reliable way to find it: the shell loads entry points by file URL and
  // the process cwd is unrelated.
  readonly property string pluginRoot: String(Qt.resolvedUrl("."))
    .replace(/^file:\/\//, "").replace(/\/$/, "")

  function refreshQueue() {
    if (queueProc.running) return
    queueProc.command = ["python3", queueScript]
    queueProc.running = true
  }

  Process {
    id: queueProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var text = String(this.text || "")
        if (!text) return
        try {
          var parsed = JSON.parse(text)
          root.queue = parsed
          root.queueLoaded = true
        } catch (error) {
          // A torn read (musicfox rewriting the file mid-scan) is normal; the
          // next tick picks it up.
        }
      }
    }
  }

  Timer {
    id: queuePoll
    interval: root.queuePollMs
    repeat: true
    running: root.running
    onTriggered: root.refreshQueue()
  }

  // Also re-read the queue whenever we type something: the play mode and the
  // queue cursor both live only in the TUI, and a keystroke is the only thing
  // that moves them.
  property int lastInteraction: 0
  onLastInteractionChanged: refreshQueue()

  Connections {
    target: root.player
    ignoreUnknownSignals: true
    function onInteractionTickChanged() {
      root.lastInteraction = root.player.interactionTick
      if (root.readPlayMode) modePoll.restart()
    }
    function onPlayersChanged() { root.refreshQueue() }
  }

  onRunningChanged: if (running) refreshQueue()

  // ------------------------------------------------------------- artwork
  //
  // The CDN link in mpris:artUrl is http:// and re-fetched by Qt every time the
  // source string changes, so we hand the same URL to the Image as-is and let
  // Qt's cache do the work.

  property string artUrl: ""
  function refreshArt() {
    artUrl = trackArtUrl
  }
  onTrackArtUrlChanged: refreshArt()

  // ------------------------------------------------------------ top level

  // "Start" means "get audio playing", not "ensure a process exists". Those
  // are different states and the second one is reachable by a single click:
  // launch() brings musicfox up with an empty queue, MPRIS reports Stopped with
  // no track, and it stays silent until something tells it to load one.
  //
  // So: launch when there is no process, and press the TUI's space key when
  // there is a process but nothing loaded. Space is the only path that both
  // loads a track and opens an audio stream (see the cold-start note above).
  function start() {
    if (!player) return
    if (!player.available) {
      player.launch()
      // A freshly launched musicfox takes several seconds to register on the
      // bus and starts Stopped with an empty queue. Clicking "start" and having
      // nothing play is the worst possible answer, so follow the launch up with
      // the same key press a second click would send.
      warmUp.attempts = 0
      warmUp.restart()
      return
    }
    if (machine === null || !hasTrack) {
      player.togglePlaying()
      return
    }
    if (!isPlaying) play()
  }

  // Waits for the launched player to appear, then presses space once. Bounded
  // so a musicfox that fails to start does not leave a timer poking at a
  // nonexistent session forever.
  Timer {
    id: warmUp
    property int attempts: 0
    interval: 1500
    repeat: false
    onTriggered: {
      attempts += 1
      if (machine === null || !hasTrack) {
        if (machine !== null && player && player.available) player.togglePlaying()
        if (attempts < 12) restart()
      }
    }
  }

  Component.onCompleted: {
    refreshQueue()
    queuePoll.start()
    refreshArt()
  }
}
