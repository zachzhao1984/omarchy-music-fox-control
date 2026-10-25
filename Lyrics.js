// LRC parser for musicfox.
//
// musicfox does not publish MPRIS metadata the way most players do: instead of
// a clean title/artist pair it stuffs the whole timed lyric, translations
// included, into `xesam:asText`. A real payload looks like:
//
//   [00:00.00]作词: Albert Hammond Jr/Diane Warren
//   [00:22.98]Looking in your eyes I see a paradise [望着你的双眼 我看见了天堂]
//   [00:27.53]This world that I've found [我发现的世界]
//
// so the translation shares the line instead of living in a second timestamped
// track. We split it back out on the last bracketed run.
//
// The same field also carries two kinds of non-lyric:
//   [00:00.00]No lyrics available.~
//       An instrumental or a track with no lyric in NetEase's database.
//   [00:00.00]作词: X [00:01.00]作曲: Y
//       A credit block. Real lyrics always follow at least one timed line that
//       is not a credit, so a payload where EVERY line is a credit is a header
//       with no song behind it.
// Both are reported as an empty lyric so the panel hides the section instead of
// rendering "No lyrics available.~" as the first line forever.

.pragma library

// "作词:" / "作曲:" / "制作人:" / "Lyricist:" / "Composer:" ...
var CREDIT_PATTERN = /^\s*(作词|作曲|编曲|制作人|出品|监制|混音|母带|录音|和声|吉他|贝斯|鼓|弦乐|词|曲|OP|SP|Lyricist|Composer|Arranger|Producer|Mixed|Mastered)\s*[:：]/i

// musicfox's sentinel for "NetEase has no lyric for this track".
var PLACEHOLDER_PATTERN = /^\s*No lyrics available\.?~?\s*$/i

// "[01:02.34]" / "[1:02]" / "[01:02:34]" -> seconds. Returns -1 when unparsable.
function parseTimestamp(tag) {
  var m = String(tag).match(/^\s*(\d+):(\d{1,2})(?:[.:](\d{1,3}))?\s*$/)
  if (!m) return -1
  var minutes = parseInt(m[1], 10)
  var seconds = parseInt(m[2], 10)
  var fraction = m[3] ? parseInt(m[3], 10) / Math.pow(10, m[3].length) : 0
  if (!isFinite(minutes) || !isFinite(seconds)) return -1
  return minutes * 60 + seconds + fraction
}

// Split "原文 [翻译]" into its two halves. The translation may also arrive on
// its own line, which the caller handles by leaving `text` empty and merging.
function splitTranslation(line) {
  var match = String(line).match(/^(.*?)\s*\[([^\]]*)\]\s*$/)
  if (!match) return { text: line, translation: "" }
  var head = match[1].replace(/\s+$/, "")
  var tail = match[2].replace(/^\s+|\s+$/g, "")
  if (!head) return { text: "", translation: tail }
  return { text: head, translation: tail }
}

// Returns [{ time, text, translation }] sorted by time. Lines with no
// timestamp (musicfox's "[00:00.00]No lyrics available.~" placeholder, or
// untimed headers) are dropped rather than pinned to 0.
function parse(lrc) {
  var raw = typeof lrc === "string" ? lrc : ""
  if (!raw) return []

  var out = []
  var lines = raw.split(/\r?\n/)
  var previous = null

  for (var i = 0; i < lines.length; i++) {
    var line = lines[i]
    if (!line) continue

    // A line may carry several timestamps ("[00:10.00][01:20.00]chorus").
    var stamps = []
    var rest = line
    var stamp = rest.match(/^\s*\[(\d+:\d{1,2}(?:[.:]\d{1,3})?)\]\s*/)
    while (stamp) {
      stamps.push(parseTimestamp(stamp[1]))
      rest = rest.slice(stamp[0].length)
      stamp = rest.match(/^\s*\[(\d+:\d{1,2}(?:[.:]\d{1,3})?)\]\s*/)
    }

    var parts = splitTranslation(rest)
    var text = parts.text
    var translation = parts.translation

    // Drop the "no lyric" sentinel wherever it appears; it is never real text.
    if (PLACEHOLDER_PATTERN.test(text)) text = ""
    if (PLACEHOLDER_PATTERN.test(translation)) translation = ""

    if (stamps.length === 0) {
      // Untimed continuation: a translation-only line belongs to the line
      // above it. Anything else is a header we do not want in the scroll.
      if (previous && !text && translation) previous.translation = translation
      continue
    }

    for (var s = 0; s < stamps.length; s++) {
      var at = stamps[s]
      if (at < 0) continue
      var entry = { time: at, text: text, translation: translation }
      out.push(entry)
      previous = entry
    }
  }

  // musicfox's placeholder for "this track has no lyric", either the sentinel
  // string or an all-credit header block.
  var hasText = false
  var hasContent = false
  for (var k = 0; k < out.length; k++) {
    var line0 = out[k]
    if (!line0.text && !line0.translation) continue
    hasText = true
    if (line0.text && !CREDIT_PATTERN.test(line0.text)) { hasContent = true; break }
  }
  if (!hasText) return []
  if (!hasContent) return []

  out.sort(function(a, b) { return a.time - b.time })
  return out
}

// Index of the line that should be highlighted at `position` seconds.
// Returns -1 before the first line, and the last index once past the end.
function indexAt(lines, position) {
  if (!lines || lines.length === 0) return -1
  var pos = Number(position) || 0
  if (pos < lines[0].time) return -1

  var low = 0
  var high = lines.length - 1
  var found = 0
  while (low <= high) {
    var mid = (low + high) >> 1
    if (lines[mid].time <= pos) { found = mid; low = mid + 1 }
    else high = mid - 1
  }
  return found
}

// "03:42" — the compact form used next to the progress bar. Hours are dropped
// because a NetEase track never runs that long, but a stray value still
// renders as minutes rather than "NaN".
function formatClock(seconds) {
  var total = Math.floor(Number(seconds) || 0)
  if (total < 0) total = 0
  var m = Math.floor(total / 60)
  var s = total % 60
  return (m < 10 ? "0" : "") + m + ":" + (s < 10 ? "0" : "") + s
}
