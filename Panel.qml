import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Commons as Commons
import qs.Ui
import "Lyrics.js" as Lyrics

// The panel: artwork, transport, a seek bar, volume, the live lyric, and the
// queue musicfox has persisted.
//
// Keyboard-first like the rest of the shell: arrows/hjkl move, space or enter
// activates, p cycles the play mode, q/escape closes.
Panel {
  id: root
  moduleName: "io.github.musicfox.control"
  ipcTarget: "io.github.musicfox.control"
  manageIpc: false

  property var anchorItem: null
  property var hostWidget: null
  property var shell: null
  readonly property var barIdentity: hostWidget || root

  readonly property var barIdentityItem: barIdentity

  // The three transport buttons are pinned to one height from the theme's
  // control scale. Deriving it from the buttons' own implicitHeight would feed
  // back on itself (the row sizes the buttons, the buttons size the row), and
  // letting each button keep its natural height is exactly what made the play
  // glyph sit proud of its neighbours.
  readonly property int transportButtonSize: Style.spacing.controlHeight + Style.spacing.md * 2

  // Height of the now-playing block. Declared on the root rather than derived
  // from its children: the artwork, the metadata column and the control stack
  // all anchor their vertical centres to this value, so reading any of their
  // heights back into it is a binding cycle — the children then position
  // themselves against a stale zero and the whole block collapses upwards.
  readonly property int artworkSize: Style.space(88)
  // PanelSlider's own implicitHeight can exceed a plain text row, so the
  // volume band is sized off the slider rather than a guessed constant.
  readonly property int volumeRowHeight: Math.max(Style.space(20), volumeSlider.implicitHeight)
  // The control stack is: one button row, the Column gap, then the volume row.
  readonly property int controlStackHeight: transportButtonSize + Style.space(8) + volumeRowHeight
  readonly property int nowPlayingHeight: Math.max(artworkSize, controlStackHeight)

  // Queue row geometry. Sized off the font scale like everything else, so a
  // larger base font grows the covers with the text instead of clipping them.
  readonly property int queueCoverSize: Style.space(36)
  readonly property int queueRowHeight: Math.max(Style.space(42), queueCoverSize + Style.space(8))

  // `bar` is injected by the bar widget when the panel is opened by clicking
  // it. A panel summoned over IPC, or opened before its host widget has wired
  // itself up, arrives with `bar === null`, and every theme lookup below reads
  // `bar.foreground` / `bar.fontFamily`. Rather than guard fifty bindings, fall
  // back to the same palette the bar would hand us.
  readonly property QtObject themeBar: bar ? bar : fallbackBar

  readonly property QtObject fallbackBar: QtObject {
    property color foreground: Commons.Color.foreground
    property color barForeground: Commons.Color.foreground
    property color background: Commons.Color.background
    property string fontFamily: Style.font.family
    property bool vertical: false
    property bool foregroundAnimationEnabled: true
    property int barSize: Style.bar.sizeHorizontal
    property var activePopout: null
    function showTooltip() {}
    function hideTooltip() {}
    function requestPopout() {}
    function releasePopout() {}
  }

  // Route the MPRIS-facing model and the tmux-facing player through one place
  // so the bar widget can read the same state.
  readonly property var player: Player {
    id: playerController
  }

  readonly property var model: Model {
    id: state
    shell: root.shell
    player: playerController
    // Only scrape the play-mode footer while the panel can show it.
    readPlayMode: root.opened
  }

  // ------------------------------------------------------------ navigation

  // Keyboard focus ring over the controls, in the same idiom as omarchy.audio.
  //
  // -1 means "nothing focused yet". Starting at 0 put the ring on the previous
  // button the moment the panel opened, which painted a highlight fill and
  // border on that one button only — it read as a misaligned/oddly-sized button
  // next to two plain ones, when the geometry was in fact identical.
  property int cursor: -1
  readonly property var controls: [
    "previous", "toggle", "next", "loop", "seek", "volume", "queue"
  ]
  readonly property string focusControl: cursor < 0
    ? ""
    : controls[Math.max(0, Math.min(cursor, controls.length - 1))]

  function moveCursor(dx, dy) {
    if (cursor < 0) {
      // First movement enters the ring at the transport cluster.
      cursor = dx < 0 || dy < 0 ? controls.length - 1 : 0
      return
    }
    if (dy !== 0) {
      cursor = (cursor + (dy > 0 ? 1 : -1) + controls.length) % controls.length
      return
    }
    if (dx === 0) return
    var next = cursor + dx
    cursor = Math.max(0, Math.min(next, controls.length - 1))
  }

  function activateCursor() {
    switch (focusControl) {
      case "previous": model.previous(); break
      case "toggle": model.togglePlaying(); break
      case "next": model.next(); break
      case "loop": model.toggleSingleLoop(); break
      case "seek": model.seekBackward(5); break
      case "volume": model.setVolume(model.volume > 0.5 ? 0.3 : 0.7); break
      case "queue": model.refreshQueue(); break
    }
  }

  function open() {
    model.refreshQueue()
    refreshSaveState()
    root.controller.show()
  }

  function openFromHotkey() {
    model.refreshQueue()
    refreshSaveState()
    root.controller.show()
  }

  function close() {
    root.controller.hide()
  }

  function toggle() {
    if (root.opened) root.close()
    else root.openFromHotkey()
  }

  // -------------------------------------------------- volatile user settings
  //
  // "Restore playback on start" is the only setting this panel writes, because
  // it is the difference between "the bar widget works" and "the bar widget
  // works after you open a terminal and press space". It lives in musicfox's
  // own config, not in shell.json, since musicfox is what reads it.
  //
  // Everything about musicfox's config file handling is deliberately careful:
  // the file is TOML with comments the user probably cares about, so we rewrite
  // exactly one key in place and leave the rest byte-identical.

  readonly property string musicfoxConfigDir: (Quickshell.env("XDG_CONFIG_HOME")
    || (Quickshell.env("HOME") + "/.config")) + "/go-musicfox"
  readonly property string musicfoxConfigPath: musicfoxConfigDir + "/config.toml"
  readonly property string configScript: model.pluginScript("scripts/config.py")

  property bool autoplayEnabled: false
  property string autoplayEngine: ""
  property bool configLoaded: false

  function refreshSaveState() {
    if (configRead.running) return
    configRead.command = ["python3", configScript, "read", musicfoxConfigPath]
    configRead.running = true
  }

  Process {
    id: configRead
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var text = String(this.text || "")
        if (!text) return
        try {
          var parsed = JSON.parse(text)
          root.autoplayEnabled = parsed.autoplay === true
          root.autoplayEngine = String(parsed.engine || "")
          root.configLoaded = true
          // Requirement surfaced in the panel rather than in a log: musicfox's
          // beep engine panics on MPRIS Pause/Next (nil timer), so this plugin
          // only claims to work on mpv.
          root.engineOk = root.autoplayEngine === "mpv"
        } catch (error) {}
      }
    }
    onExited: {}
  }

  property bool engineOk: true

  function setAutoplay(enabled) {
    if (configWrite.running) return
    configWrite.command = ["python3", configScript, "set-autoplay", musicfoxConfigPath, enabled ? "true" : "false"]
    configWrite.running = true
  }

  Process {
    id: configWrite
    stdout: StdioCollector { waitForEnd: true }
    onExited: function(code) {
      if (code === 0) root.autoplayEnabled = !root.autoplayEnabled
      root.refreshSaveState()
      refreshSaveStateTimer.restart()
    }
  }

  Timer {
    id: refreshSaveStateTimer
    interval: 400
    onTriggered: root.refreshSaveState()
  }

  // -------------------------------------------------------------- keyboard

  // The seek bar and the volume slider are the only rows that want horizontal
  // nudges; everything else moves the ring.
  function nudge(direction) {
    if (focusControl === "seek") {
      model.seekBy(direction * 10)
      return true
    }
    return false
  }

  // ------------------------------------------------------------------- UI

  KeyboardPanel {
    id: panel
    anchorItem: root.anchorItem
    owner: root.barIdentityItem
    bar: root.themeBar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(Number(root.setting("panelWidth", 380)) || 380))
    contentHeight: panel.fittedContentHeight(column.implicitHeight)

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onMoveRequested: function(dx, dy) {
        if (dx !== 0 && root.nudge(dx)) return
        root.moveCursor(dx, dy)
      }
      onActivateRequested: root.activateCursor()
      onCloseRequested: root.close()
      onTextKey: function(text) {
        if (text === "p") model.cyclePlayMode(false)
        else if (text === "P") model.cyclePlayMode(true)
        else if (text === " ") model.togglePlaying()
        else if (text === "r") model.refreshQueue()
      }

      Flickable {
        id: scroll
        anchors.fill: parent
        contentWidth: width
        contentHeight: column.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        interactive: contentHeight > height

        Column {
          id: column
          width: scroll.width
          spacing: Style.space(12)

          // =================================================== no player
          Column {
            width: parent.width
            spacing: Style.space(10)
            visible: !state.running

            Text {
              textFormat: Text.PlainText
              text: "󰝛"
              color: root.themeBar.foreground
              font.family: root.themeBar.fontFamily
              font.pixelSize: Style.font.displayLarge
              anchors.horizontalCenter: parent.horizontalCenter
            }

            Text {
              textFormat: Text.PlainText
              text: qsTr("musicfox is not running")
              color: root.themeBar.foreground
              font.family: root.themeBar.fontFamily
              font.pixelSize: Style.font.subtitle
              font.bold: true
              anchors.horizontalCenter: parent.horizontalCenter
            }

            Text {
              width: parent.width
              textFormat: Text.PlainText
              text: qsTr("Start it in a background tmux session, or launch it in a terminal to pick a playlist first.")
              color: Qt.darker(root.themeBar.foreground, 1.4)
              font.family: root.themeBar.fontFamily
              font.pixelSize: Style.font.bodySmall
              horizontalAlignment: Text.AlignHCenter
              wrapMode: Text.WordWrap
            }

            Row {
              anchors.horizontalCenter: parent.horizontalCenter
              spacing: Style.space(8)

              Button {
                text: qsTr("Start")
                foreground: root.themeBar.foreground
                bordered: true
                onClicked: playerController.launch()
              }

              Button {
                text: qsTr("Open terminal")
                foreground: root.themeBar.foreground
                bordered: true
                onClicked: Quickshell.execDetached([
                  "omarchy-launch-tui", "--app-id=org.omarchy.musicfox", "musicfox", "netease"
                ])
              }
            }
          }

          // ==================================================== now playing
          //
          // Artwork on the left, then a column with the track metadata, then the
          // transport cluster pinned to the right of that same row. Putting the
          // controls here keeps them next to the artwork they act on instead of
          // floating in a full-width band underneath.
          // Artwork | metadata | controls, one horizontal band.
          //
          // A Row lays children out left to right and aligns them to the top,
          // so each child is given `anchors.verticalCenter` against the row's
          // fixed height. The height is a constant from the root: deriving it
          // from a child that in turn centres against it is a binding cycle,
          // and Qt resolves that cycle to a stale value, which is what pushed
          // the control stack below the artwork.
          Row {
            id: nowPlayingRow
            width: parent.width
            height: root.nowPlayingHeight
            spacing: Style.space(12)
            visible: state.running

            BorderSurface {
              id: artworkTile
              width: root.artworkSize
              height: root.artworkSize
              anchors.verticalCenter: parent.verticalCenter
              radius: Style.spacing.labelGap
              color: Style.normalFillFor(root.themeBar.foreground, Commons.Color.accent)
              borderSpec: Border.controlSpec("normal", root.themeBar.foreground, Commons.Color.accent)

              Image {
                anchors.fill: parent
                anchors.margins: Style.space(2)
                fillMode: Image.PreserveAspectCrop
                asynchronous: true
                cache: true
                source: state.artUrl
                visible: source !== "" && status === Image.Ready
              }

              Text {
                anchors.centerIn: parent
                visible: !state.artUrl || artImage.status !== Image.Ready
                text: "󰝚"
                color: root.themeBar.foreground
                font.family: root.themeBar.fontFamily
                font.pixelSize: Style.font.displayLarge
              }

              Image {
                id: artImage
                visible: false
                source: state.artUrl
              }
            }

            // Metadata takes the slack between artwork and controls.
            Column {
              id: metaColumn
              width: Math.max(0, nowPlayingRow.width - root.artworkSize - controlCluster.width - Style.space(24))
              anchors.verticalCenter: parent.verticalCenter
              spacing: Style.space(3)

              Text {
                width: parent.width
                textFormat: Text.PlainText
                text: state.trackTitle !== "" ? state.trackTitle : qsTr("Nothing playing")
                color: root.themeBar.foreground
                font.family: root.themeBar.fontFamily
                font.pixelSize: Style.font.subtitle
                font.bold: true
                elide: Text.ElideRight
              }

              Text {
                width: parent.width
                textFormat: Text.PlainText
                text: state.trackArtist
                color: Qt.darker(root.themeBar.foreground, 1.3)
                font.family: root.themeBar.fontFamily
                font.pixelSize: Style.font.bodySmall
                elide: Text.ElideRight
                visible: text !== ""
              }

              Text {
                width: parent.width
                textFormat: Text.PlainText
                text: state.trackAlbum
                color: Qt.darker(root.themeBar.foreground, 1.6)
                font.family: root.themeBar.fontFamily
                font.pixelSize: Style.font.caption
                elide: Text.ElideRight
                visible: text !== ""
              }

              Text {
                width: parent.width
                textFormat: Text.PlainText
                text: state.loggedIn
                  ? qsTr("网易云 · %1").arg(state.nickname !== "" ? state.nickname : qsTr("logged in"))
                  : qsTr("未登录 · log in inside musicfox")
                color: state.loggedIn
                  ? Qt.darker(root.themeBar.foreground, 1.6)
                  : Commons.Color.urgent
                font.family: root.themeBar.fontFamily
                font.pixelSize: Style.font.caption
                elide: Text.ElideRight
                visible: state.queueLoaded
              }
            }

            // The whole right-hand control surface is one Column: transport
            // row on top, volume directly beneath it.
            Column {
              id: controlCluster
              anchors.verticalCenter: parent.verticalCenter
              spacing: Style.space(8)

              Row {
                id: transportRow
                spacing: Style.space(2)

                Button {
                  id: prevButton
                  iconText: "󰒮"
                  iconSize: Style.font.iconLarge
                  height: root.transportButtonSize
                  foreground: root.themeBar.foreground
                  hasCursor: root.focusControl === "previous"
                  enabled: state.canGoPrevious
                  opacity: enabled ? 1.0 : 0.4
                  onClicked: model.previous()
                }

                Button {
                  id: toggleButton
                  iconText: state.isPlaying ? "󰏤" : "󰐊"
                  iconSize: Style.font.iconLarge
                  height: root.transportButtonSize
                  foreground: root.themeBar.foreground
                  hasCursor: root.focusControl === "toggle"
                  onClicked: state.hasTrack ? model.togglePlaying() : state.play()
                }

                Button {
                  id: nextButton
                  iconText: "󰒭"
                  iconSize: Style.font.iconLarge
                  height: root.transportButtonSize
                  foreground: root.themeBar.foreground
                  hasCursor: root.focusControl === "next"
                  enabled: state.canGoNext
                  opacity: enabled ? 1.0 : 0.4
                  onClicked: model.next()
                }

                Item { width: Style.space(4); height: 1 }

                // Single-loop toggle, same footprint as its neighbours.
                // `selected` carries the on/off state; `bordered` is avoided
                // because Button reserves border width in its implicit size,
                // which would make this one a couple of pixels larger.
                Button {
                  id: loopButton
                  width: root.transportButtonSize
                  height: root.transportButtonSize
                  iconText: "󰑘"
                  // repeat-once has a taller/wider ink than the arrows, so it
                  // is drawn one step smaller to match their optical weight.
                  iconSize: Style.font.icon
                  selected: state.singleLoop
                  foreground: state.singleLoop ? Commons.Color.accent : root.themeBar.foreground
                  hasCursor: root.focusControl === "loop"
                  tooltipText: state.singleLoop ? qsTr("Single loop: on") : qsTr("Single loop: off")
                  onClicked: model.toggleSingleLoop()
                }
              }

              // Volume spans exactly the transport row: glyph left, percentage
              // right, slider taking the middle.
              Item {
                id: volumeRow
                width: transportRow.width
                height: root.volumeRowHeight
                visible: state.volumeSupported

                Text {
                  id: volumeGlyph
                  anchors.left: parent.left
                  anchors.verticalCenter: parent.verticalCenter
                  textFormat: Text.PlainText
                  text: state.volume <= 0.001 ? "󰝟" : (state.volume < 0.5 ? "󰖀" : "󰕾")
                  color: root.themeBar.foreground
                  font.family: root.themeBar.fontFamily
                  font.pixelSize: Style.font.body
                }

                Text {
                  id: volumePercent
                  anchors.right: parent.right
                  anchors.verticalCenter: parent.verticalCenter
                  textFormat: Text.PlainText
                  text: Math.round(state.volume * 100) + "%"
                  color: Qt.darker(root.themeBar.foreground, 1.4)
                  font.family: root.themeBar.fontFamily
                  font.pixelSize: Style.font.caption
                }

                PanelSlider {
                  id: volumeSlider
                  anchors.left: volumeGlyph.right
                  anchors.right: volumePercent.left
                  anchors.leftMargin: Style.space(6)
                  anchors.rightMargin: Style.space(6)
                  anchors.verticalCenter: parent.verticalCenter
                  bar: root.themeBar
                  minimum: 0
                  maximum: 1
                  step: 0.01
                  value: state.volume
                  onMoved: function(v) { model.setVolume(v) }
                  onReleased: function(v) { model.setVolume(v) }
                }
              }
            }
          }

          // ========================================================= seek
          Column {
            width: parent.width
            spacing: Style.space(3)
            visible: state.running && state.length > 0

            // PanelSlider drives `value` from outside unless it is being
            // dragged, which is exactly what we want: MPRIS keeps ticking, the
            // knob follows, and the user's drag wins while it lasts.
            PanelSlider {
              id: seekSlider
              width: parent.width
              bar: root.themeBar
              minimum: 0
              maximum: Math.max(1, state.length)
              value: state.position
              step: 1
              onMoved: function(v) { if (!dragging) model.seekTo(v) }
              onReleased: function(v) { model.seekTo(v) }
            }

            Item {
              width: parent.width
              height: timeRow.implicitHeight

              Row {
                id: timeRow
                anchors.left: parent.left
                spacing: Style.space(4)

                Text {
                  textFormat: Text.PlainText
                  text: Lyrics.formatClock(state.position)
                  color: Qt.darker(root.themeBar.foreground, 1.4)
                  font.family: root.themeBar.fontFamily
                  font.pixelSize: Style.font.caption
                }
              }

              Text {
                anchors.right: parent.right
                textFormat: Text.PlainText
                text: Lyrics.formatClock(state.length)
                color: Qt.darker(root.themeBar.foreground, 1.4)
                font.family: root.themeBar.fontFamily
                font.pixelSize: Style.font.caption
              }
            }
          }

          // ====================================================== lyrics
          Column {
            width: parent.width
            spacing: Style.space(4)
            visible: state.running && state.lyricLines.length > 0

            PanelSectionHeader {
              text: qsTr("Lyrics")
              foreground: root.themeBar.foreground
            }

            Item {
              width: parent.width
              height: Math.min(Style.space(160), lyricColumn.implicitHeight)

              Flickable {
                id: lyricScroll
                anchors.fill: parent
                contentWidth: width
                contentHeight: lyricColumn.implicitHeight
                clip: true
                boundsBehavior: Flickable.StopAtBounds
                interactive: contentHeight > height

                Column {
                  id: lyricColumn
                  width: lyricScroll.width
                  spacing: Style.space(5)

                  Repeater {
                    model: state.lyricLines

                    Item {
                      id: lyricRow
                      required property var modelData
                      required property int index

                      readonly property bool current: index === state.lyricIndex

                      width: lyricColumn.width
                      height: lyricRowInner.implicitHeight

                      Column {
                        id: lyricRowInner
                        width: parent.width
                        spacing: Style.space(1)

                        Text {
                          width: parent.width
                          textFormat: Text.PlainText
                          text: lyricRow.modelData.text
                          color: lyricRow.current
                            ? Commons.Color.accent
                            : Qt.darker(root.themeBar.foreground, 1.9)
                          font.family: root.themeBar.fontFamily
                          font.pixelSize: lyricRow.current ? Style.font.body : Style.font.bodySmall
                          font.bold: lyricRow.current
                          wrapMode: Text.WordWrap
                        }

                        Text {
                          width: parent.width
                          textFormat: Text.PlainText
                          text: lyricRow.modelData.translation
                          color: lyricRow.current
                            ? Qt.darker(Commons.Color.accent, 1.15)
                            : Qt.darker(root.themeBar.foreground, 2.4)
                          font.family: root.themeBar.fontFamily
                          font.pixelSize: Style.font.caption
                          wrapMode: Text.WordWrap
                          visible: text !== ""
                        }
                      }
                    }
                  }
                }
              }

              // Keep the highlighted line in view without yanking the list
              // while the user is reading it.
              Connections {
                target: state
                function onLyricIndexChanged() {
                  if (!lyricColumn || state.lyricIndex < 0) return
                  var item = lyricColumn.children[state.lyricIndex]
                  if (!item) return
                  var top = item.y
                  var bottom = top + item.height
                  if (top < lyricScroll.contentY)
                    lyricScroll.contentY = top
                  else if (bottom > lyricScroll.contentY + lyricScroll.height)
                    lyricScroll.contentY = bottom - lyricScroll.height
                }
              }
            }
          }

          // ======================================================= queue
          //
          // Current track plus the next few, each with its album cover so the
          // list is scannable at a glance instead of a wall of text. The covers
          // come from the same `album.pic_url` field musicfox persists for every
          // queued track, so no extra request is involved — just the CDN links
          // the player already has.
          Column {
            id: queueColumn
            width: parent.width
            spacing: Style.space(2)
            visible: state.running && state.queueLength > 0

            PanelSectionHeader {
              text: qsTr("Queue") + "  ·  " + (state.queueIndex + 1) + "/" + state.queueLength
              foreground: root.themeBar.foreground
            }

            Repeater {
              model: state.upcomingTracks

              Item {
                id: queueRow
                required property var modelData
                required property int index

                readonly property bool current: index === 0
                readonly property var track: modelData
                readonly property string cover: track && track.artUrl ? String(track.artUrl) : ""
                readonly property string title: track && track.name ? String(track.name) : ""
                readonly property string artist: track && track.artist ? String(track.artist) : ""

                width: queueColumn.width
                height: root.queueRowHeight
                // A faint fill behind the playing row marks the cursor without
                // a bullet glyph, which would otherwise collide with the cover.
                Rectangle {
                  anchors.fill: parent
                  radius: Style.spacing.labelGap
                  color: queueRow.current
                    ? Style.selectedFillFor(root.themeBar.foreground, Commons.Color.accent)
                    : "transparent"
                }

                BorderSurface {
                  id: queueCover
                  width: root.queueCoverSize
                  height: root.queueCoverSize
                  anchors.left: parent.left
                  anchors.leftMargin: Style.space(4)
                  anchors.verticalCenter: parent.verticalCenter
                  radius: Style.space(2)
                  color: Style.normalFillFor(root.themeBar.foreground, Commons.Color.accent)
                  borderSpec: Border.none()

                  // Small tile: inset by a fixed 1 px so the rounded corners
                  // still show the cover edge. Using Style.space(1) here would
                  // scale with the base font and eat a noticeable slice of a
                  // 45 px tile.
                  Image {
                    id: queueCoverImage
                    anchors.fill: parent
                    anchors.margins: 1
                    fillMode: Image.PreserveAspectCrop
                    asynchronous: true
                    cache: true
                    source: queueRow.cover
                    visible: source !== "" && status === Image.Ready
                  }

                  // Cover art is not always present (local uploads, radio
                  // episodes), so the tile keeps its shape with a glyph inside.
                  Text {
                    anchors.centerIn: parent
                    visible: queueCover.visible && (!queueRow.cover || queueCoverImage.status !== Image.Ready)
                    text: "󰝚"
                    color: Qt.darker(root.themeBar.foreground, 1.5)
                    font.family: root.themeBar.fontFamily
                    font.pixelSize: Style.font.bodySmall
                  }

                }

                Column {
                  anchors.left: queueCover.right
                  anchors.right: parent.right
                  anchors.leftMargin: Style.space(8)
                  anchors.rightMargin: Style.space(4)
                  anchors.verticalCenter: parent.verticalCenter
                  spacing: 0

                  Text {
                    width: parent.width
                    textFormat: Text.PlainText
                    text: queueRow.title
                    color: queueRow.current
                      ? Commons.Color.accent
                      : root.themeBar.foreground
                    font.family: root.themeBar.fontFamily
                    font.pixelSize: Style.font.bodySmall
                    font.bold: queueRow.current
                    elide: Text.ElideRight
                  }

                  Text {
                    width: parent.width
                    textFormat: Text.PlainText
                    text: queueRow.artist
                    color: Qt.darker(root.themeBar.foreground, 1.7)
                    font.family: root.themeBar.fontFamily
                    font.pixelSize: Style.font.caption
                    elide: Text.ElideRight
                    visible: text !== ""
                  }
                }
              }
            }

            Text {
              width: parent.width
              textFormat: Text.PlainText
              text: qsTr("Picking a track needs musicfox's own menu — open the terminal to navigate the queue.")
              color: Qt.darker(root.themeBar.foreground, 2.0)
              font.family: root.themeBar.fontFamily
              font.pixelSize: Style.font.caption
              wrapMode: Text.WordWrap
              topPadding: Style.space(4)
            }
          }

          // ====================================================== actions
          Row {
            width: parent.width
            spacing: Style.space(6)
            visible: state.running

            Button {
              text: qsTr("Open player")
              foreground: root.themeBar.foreground
              bordered: true
              onClicked: {
                playerController.focusPlayer()
                root.close()
              }
            }

            Button {
              text: qsTr("Quit")
              foreground: root.themeBar.foreground
              bordered: true
              onClicked: {
                playerController.stop()
                root.close()
              }
            }
          }

          // ============================================== engine warning
          //
          // musicfox's default engine on Linux is beep, whose player panics on
          // a nil timer when MPRIS pauses or skips before it has real audio.
          // That kills the whole process, so the plugin refuses to pretend it
          // will work and says what to change.
          BorderSurface {
            width: parent.width
            visible: state.running && root.configLoaded && !root.engineOk
            height: warnColumn.implicitHeight + Style.space(16)
            radius: Style.spacing.labelGap
            color: "transparent"
            borderSpec: Border.controlSpec("normal", Commons.Color.urgent, Commons.Color.urgent)

            Column {
              id: warnColumn
              anchors.left: parent.left
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              anchors.margins: Style.space(8)
              spacing: Style.space(3)

              Text {
                width: parent.width
                textFormat: Text.PlainText
                text: qsTr("player.engine is \"%1\"").arg(root.autoplayEngine !== "" ? root.autoplayEngine : qsTr("unset"))
                color: Commons.Color.urgent
                font.family: root.themeBar.fontFamily
                font.pixelSize: Style.font.bodySmall
                font.bold: true
              }

              Text {
                width: parent.width
                textFormat: Text.PlainText
                text: qsTr("Set player.engine = \"mpv\" in ~/.config/go-musicfox/config.toml. The built-in beep engine crashes musicfox when MPRIS pauses or skips.")
                color: Qt.darker(root.themeBar.foreground, 1.3)
                font.family: root.themeBar.fontFamily
                font.pixelSize: Style.font.caption
                wrapMode: Text.WordWrap
              }
            }
          }

          // ============================================== restore-on-start
          Row {
            width: parent.width
            spacing: Style.space(8)
            visible: state.running && root.configLoaded

            Text {
              width: parent.width - restoreSwitch.width - Style.space(8)
              textFormat: Text.PlainText
              text: qsTr("Restore playback when the bar starts it")
              color: Qt.darker(root.themeBar.foreground, 1.2)
              font.family: root.themeBar.fontFamily
              font.pixelSize: Style.font.bodySmall
              wrapMode: Text.WordWrap
              anchors.verticalCenter: parent.verticalCenter
            }

            ToggleSwitch {
              id: restoreSwitch
              checked: root.autoplayEnabled
              onToggled: root.setAutoplay(!root.autoplayEnabled)
            }
          }
        }
      }
    }
  }
}
