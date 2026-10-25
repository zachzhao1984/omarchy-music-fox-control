import QtQuick
import Quickshell
import qs.Commons
import qs.Ui

// Bar widget: a transport glyph, the current line, and — on hover — a thin
// progress line that doubles as the seek affordance.
//
// Left click toggles playback, right click opens the panel, middle click is
// configurable (next by default, matching omarchy.media), and the wheel is
// configurable (volume by default).
BarWidget {
  id: root
  moduleName: "io.github.musicfox.control"

  // Host-injected facade, used by the panel to persist settings.
  property var shell: null

  readonly property var panel: panelLoader.item

  readonly property string barMode: String(setting("barMode", "Title"))
  readonly property int maxLabelWidth: Math.max(60, Number(setting("maxLabelWidth", 180)) || 180)
  readonly property bool showLyric: setting("showLyricInBar", true) !== false
  readonly property string middleClick: String(setting("middleClick", "next"))
  readonly property string wheelAction: String(setting("wheelAction", "volume"))

  readonly property var model: panel ? panel.model : null
  readonly property bool active: model ? model.running && model.hasTrack : false
  readonly property bool playing: model ? model.isPlaying : false

  // Lyrics on the bar are the reason this widget exists: musicfox delivers a
  // timed lyric for free, and a scrolling translation-aware line is far more
  // useful at a glance than the title.
  readonly property string lyricLine: {
    if (!model || !showLyric) return ""
    if (model.currentLyric === "") return ""
    return model.currentLyricTranslation !== ""
      ? model.currentLyric + "  ·  " + model.currentLyricTranslation
      : model.currentLyric
  }

  readonly property string label: {
    if (!model || !model.running) return ""
    if (!model.hasTrack) return qsTr("musicfox")
    if (barMode === "Icon") return ""
    if (barMode === "Lyric" && lyricLine !== "") return lyricLine
    if (barMode === "Artist · Title") {
      return model.trackArtist !== "" ? model.trackArtist + "  ·  " + model.trackTitle : model.trackTitle
    }
    // "Title" mode still prefers the lyric when one is available, because a
    // static title tells you less than the line you are currently hearing.
    if (showLyric && lyricLine !== "") return lyricLine
    return model.trackTitle
  }

  // What the bar prints: transport glyph, then the label. Kept on the root so
  // WidgetButton can measure it (it sizes itself from `text`).
  // The bar has no clipping of its own: whatever string a widget returns is
  // measured and the slot grows to fit it. A full lyric line is easily 600 px,
  // which walks straight over the center cluster (clock, weather, indicators).
  // So the label is truncated to `maxLabelWidth` here, in pixels rather than
  // characters, because the bar font is proportional and CJK glyphs are about
  // twice as wide as Latin ones.
  readonly property string composedLabel: {
    if (label === "") return glyph
    // TextMetrics measures whatever its own `text` holds, and exposes elidedText
    // for exactly this job: set the string and the width, read back the
    // truncated version. Doing it here (rather than letting the label grow) is
    // what stops a full lyric line from running over the center cluster.
    labelMetrics.text = label
    labelMetrics.elideWidth = Math.max(Style.space(40), maxLabelWidth - glyphWidth)
    return glyph + "  " + labelMetrics.elidedText
  }

  // Width of the transport glyph plus the two-space separator, so the label
  // budget accounts for them. Measured through the same metrics object by
  // temporarily pointing it at the glyph.
  readonly property real glyphWidth: {
    glyphMetrics.text = glyph + "  "
    return glyphMetrics.advanceWidth
  }

  TextMetrics {
    id: labelMetrics
    font.family: root.bar ? root.bar.fontFamily : Style.font.family
    font.pixelSize: Style.font.body
    elide: Text.ElideRight
  }

  TextMetrics {
    id: glyphMetrics
    font.family: root.bar ? root.bar.fontFamily : Style.font.family
    font.pixelSize: Style.font.body
  }

  readonly property string glyph: {
    if (!model || !model.running) return "󰝛"
    if (model.stalled) return "󰒲"
    return playing ? "󰏤" : "󰐊"
  }

  function injectPanel() {
    var target = panelLoader.item
    if (!target) return
    if ("bar" in target) target.bar = root.bar
    if ("settings" in target) target.settings = root.settings
    if ("shell" in target) target.shell = root.shell
    if ("moduleName" in target) target.moduleName = root.moduleName
    // Anchor the popup to the play/pause button: it sits in the middle of the
    // cluster, so the panel opens centred under the widget rather than off one
    // edge.
    if ("anchorItem" in target) target.anchorItem = playButton
    if ("hostWidget" in target) target.hostWidget = root
  }

  // Pointer semantics live here rather than in a MouseArea signal handler, so
  // the bar's triggerPress() forwarding and the hover path both land in one
  // place when WidgetButton relays them.
  function handlePress(button) {
    if (!model) return
    if (button === Qt.RightButton) {
      togglePanel()
      return
    }
    if (button === Qt.MiddleButton) {
      if (middleClick === "next") model.next()
      else if (middleClick === "previous") model.previous()
      else if (middleClick === "playPause") model.togglePlaying()
      return
    }
    // Left click: a player with nothing loaded needs starting, not toggling.
    if (!model.running || !model.hasTrack) model.start()
    else model.togglePlaying()
  }

  function handleWheel(delta) {
    if (!model) return
    var up = delta > 0
    if (wheelAction === "volume") model.setVolume(model.volume + (up ? 0.05 : -0.05))
    else if (wheelAction === "seek") model.seekBy(up ? 10 : -10)
    else if (wheelAction === "nextPrevious") { if (up) model.previous(); else model.next() }
  }

  readonly property string tooltipText: {
    if (!model || !model.running) return qsTr("musicfox is not running — click to launch")
    if (!model.hasTrack) return qsTr("musicfox is starting")
    return model.trackTitle + (model.trackArtist ? " — " + model.trackArtist : "")
  }

  function togglePanel() { if (panel && panel.toggle) panel.toggle() }
  readonly property bool opened: panel ? panel.opened === true : false
  function open() { if (panel && panel.openFromHotkey) panel.openFromHotkey() }
  function close() { if (panel && panel.close) panel.close() }
  readonly property bool popoutSwitchClosing: panel ? panel.popoutSwitchClosing === true : false
  function closeForPopoutSwitch() { if (panel) panel.closeForPopoutSwitch() }

  // Width is summed from the buttons explicitly rather than read back from the
  // Row: the Row is laid out inside this item, so asking it for its
  // implicitWidth and feeding that into this item's width is a cycle. Qt
  // resolves such cycles by collapsing the layout, which put all three buttons
  // at the same origin and made the bar's hit test useless.
  readonly property real contentWidth: {
    var w = prevButton.implicitWidth + playButton.implicitWidth + nextButton.implicitWidth
    w += contentRow.spacing * 2
    return w
  }
  implicitWidth: root.active ? contentWidth + Style.space(12) : playButton.implicitWidth + Style.space(12)
  implicitHeight: root.barSize

  onBarChanged: injectPanel()
  onSettingsChanged: injectPanel()
  onShellChanged: injectPanel()

  // The panel is loaded but never shown by the bar: it is opened by its own
  // KeyboardPanel window. Keep it 0-sized rather than `visible: false` — an
  // invisible Loader subtree stops evaluating bindings, and the panel would
  // then never initialise its Model (so `model` stayed null and the bar label
  // was empty).
  Loader {
    id: panelLoader
    active: true
    source: Qt.resolvedUrl("Panel.qml")
    width: 1
    height: 1
    onLoaded: {
      root.injectPanel()
      Qt.callLater(root.injectPanel)
    }
  }

  // The bar forwards pointer input through its own clickTargets registry and
  // hit-tests each target with slot.mapToItem(), so one WidgetButton per
  // control is enough: the bar picks whichever contains the click. A single
  // full-width button with manual x-coordinate dispatch would work too, but
  // this way each control gets its own hover state, tooltip and disabled
  // styling for free.
  // No `anchors.centerIn: parent` here: the parent's implicitWidth is derived
  // from this row, so centring it against the parent is a binding cycle. Qt
  // resolves that cycle by giving the row no width, and every child then maps
  // to the same origin — the three buttons stack on one point and the bar's
  // hit test can only ever pick whichever was registered last.
  Row {
    id: contentRow
    anchors.fill: parent
    spacing: Style.space(2)

    // ---- previous ---------------------------------------------------------
    WidgetButton {
      id: prevButton
      bar: root.bar
      text: "󰒮"
      labelVisible: true
      tooltipText: qsTr("Previous")
      fixedHeight: root.barSize
      // The arrows only appear once there is a track to step through;
      // otherwise a stopped player would show three dead buttons.
      visible: root.active
      readonly property bool canStep: root.model ? root.model.canGoPrevious : false
      interactive: canStep
      pressable: canStep
      foreground: canStep ? root.bar.barForeground : Qt.darker(root.bar.barForeground, 1.9)
      onPressed: function(b) { if (b === Qt.LeftButton) root.model.previous() }
    }

    // ---- play / pause + label + progress ----------------------------------
    WidgetButton {
      id: playButton
      bar: root.bar
      text: root.composedLabel
      labelVisible: true
      tooltipText: root.tooltipText
      fixedHeight: root.barSize
      foreground: root.active && root.playing
        ? root.bar.barForeground
        : Qt.darker(root.bar.barForeground, 1.5)

      onPressed: function(button) { root.handlePress(button) }
      onWheelMoved: function(delta) { root.handleWheel(delta) }

      // A hairline progress track under the label. Reads as a seek bar once the
      // panel is open, and as "where are we in this song" when it is not.
      Rectangle {
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.bottom: parent.bottom
        height: Style.space(2)
        radius: height / 2
        visible: root.active && root.model !== null && root.model.length > 0
        color: Qt.rgba(root.bar.barForeground.r, root.bar.barForeground.g, root.bar.barForeground.b, 0.18)

        Rectangle {
          width: parent.width * (root.model ? root.model.progress : 0)
          height: parent.height
          radius: parent.radius
          color: root.bar.barForeground
        }
      }
    }

    // ---- next -------------------------------------------------------------
    WidgetButton {
      id: nextButton
      bar: root.bar
      text: "󰒭"
      labelVisible: true
      tooltipText: qsTr("Next")
      fixedHeight: root.barSize
      visible: root.active
      readonly property bool canStep: root.model ? root.model.canGoNext : false
      interactive: canStep
      pressable: canStep
      foreground: canStep ? root.bar.barForeground : Qt.darker(root.bar.barForeground, 1.9)
      onPressed: function(b) { if (b === Qt.LeftButton) root.model.next() }
    }
  }
}
