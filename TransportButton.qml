import QtQuick
import qs.Commons
import qs.Ui

// A step button (previous / next) for the bar.
//
// WidgetButton always paints a glyph label at Style.bar.iconSize, and that
// ceiling cannot be lowered per instance. The step arrows want to sit a little
// smaller than the play/pause glyph they flank, so this hides WidgetButton's
// own label and draws the same glyph through OpticalGlyph at a reduced
// paintedSize. Everything else — hit area, tooltip, disabled dimming, press
// feedback, bar click registration — is WidgetButton's and stays untouched.
WidgetButton {
  id: root

  // The glyph still travels in `text`: WidgetButton sizes itself and decides
  // `hasVisualContent` from it, and the label is simply never shown.
  labelVisible: false
  fixedWidth: Style.bar.iconSlot
  fixedHeight: barSize

  // The play glyph beside these draws as a text run at Style.font.body, whose
  // ink is about 0.8 of the bar icon size. Keeping the arrows a touch below
  // that leaves no doubt which control is the subject.
  readonly property real arrowSize: Math.max(1, Math.round(Style.bar.iconSize * 0.7))

  // The play glyph is a text run, so WidgetButton centres it on its figures
  // rather than on its ink, and text lands about a pixel below the ink-centred
  // middle of a button. The arrows are ink-centred, so they are dropped by the
  // same amount to sit on the bar's text line. Tied to the body font, which is
  // what moves that line.
  readonly property real baselineDrop: Math.round(Style.font.body * 0.1)

  OpticalGlyph {
    anchors.centerIn: parent
    anchors.verticalCenterOffset: root.baselineDrop
    width: Style.bar.iconCanvas
    height: Style.bar.iconCanvas
    text: root.text
    fontFamily: root.fontFamily
    fontSize: root.fontSize
    paintedSize: root.arrowSize
    color: root.foreground
    scale: root.pressScale
  }
}
