#!/usr/bin/env python3
"""Read musicfox's persisted queue and account out of its bbolt database.

Why this exists: musicfox advertises `HasTrackList = true` over MPRIS but never
implements `/org/mpris/MediaPlayer2/PlayList`, so there is no way to ask a
running instance what is next. The only durable copy of the queue is the
`playlist_snapshot` value it writes into ~/.local/share/go-musicfox/db/musicfox.db.

That file is held open by musicfox under an exclusive bbolt flock, so we must
not open it as a database. Reading the bytes is safe and cheap: bbolt leaves
leaf values contiguous inside their pages, so the JSON can be located by
scanning and brace-balanced out of the raw file.

Output: one JSON object on stdout. Never fails hard — a missing or empty
database yields `{"ok": false, ...}` so the QML side can just hide the queue.
"""

import json
import os
import sys


def default_db_path():
    root = os.environ.get("MUSICFOX_ROOT")
    if root:
        return os.path.join(root, "db", "musicfox.db")
    data_home = os.environ.get("XDG_DATA_HOME") or os.path.join(
        os.path.expanduser("~"), ".local", "share"
    )
    return os.path.join(data_home, "go-musicfox", "db", "musicfox.db")


def find_json_value(blob, key):
    """Return the decoded JSON object that follows the last `key` occurrence.

    bbolt stores the value inline after the key in leaf pages, so scanning for
    the bare key and brace-balancing forward recovers it. We take the last hit
    because repeatedly written values leave older copies behind as free pages.
    """
    needle = key.encode("utf-8")
    start = blob.rfind(needle)
    if start < 0:
        return None

    brace = blob.find(b"{", start + len(needle))
    # A value must open its object immediately (only whitespace may sit before
    # the brace); otherwise the key we matched was part of a larger payload.
    if brace < 0 or blob[start + len(needle):brace].strip():
        return None

    depth = 0
    in_string = False
    escaped = False
    for index in range(brace, len(blob)):
        byte = blob[index]
        if in_string:
            if escaped:
                escaped = False
            elif byte == 0x5C:  # backslash
                escaped = True
            elif byte == 0x22:  # quote
                in_string = False
            continue
        if byte == 0x22:
            in_string = True
        elif byte == 0x7B:  # {
            depth += 1
        elif byte == 0x7D:  # }
            depth -= 1
            if depth == 0:
                chunk = blob[brace:index + 1]
                try:
                    return json.loads(chunk.decode("utf-8"))
                except (UnicodeDecodeError, json.JSONDecodeError):
                    return None
    return None


def artist_names(track):
    artists = track.get("artists") or []
    names = []
    for artist in artists:
        name = str((artist or {}).get("name") or "").strip()
        if name:
            names.append(name)
    return " / ".join(names)


def normalize(track, index):
    album = track.get("album") or {}
    # musicfox stores durations in nanoseconds.
    nanos = track.get("duration") or 0
    try:
        seconds = int(round(float(nanos) / 1_000_000_000))
    except (TypeError, ValueError):
        seconds = 0

    radio = track.get("djRadio") or {}
    return {
        "index": index,
        "id": track.get("id") or 0,
        "name": str(track.get("name") or "").strip(),
        "artist": artist_names(track),
        "album": str(album.get("name") or "").strip(),
        "artUrl": str(album.get("pic_url") or "").strip(),
        "duration": seconds,
        # A track musicfox could not resolve to a playable NetEase source.
        "unmatched": bool(track.get("unMatched")),
        # Non-empty for podcast/radio episodes, which render differently.
        "radio": str(radio.get("name") or "").strip(),
    }


def main():
    path = sys.argv[1] if len(sys.argv) > 1 else default_db_path()
    if not os.path.isfile(path):
        print(json.dumps({"ok": False, "reason": "missing", "path": path}))
        return 0

    try:
        with open(path, "rb") as handle:
            blob = handle.read()
    except OSError as error:
        print(json.dumps({"ok": False, "reason": "unreadable", "error": str(error), "path": path}))
        return 0

    snapshot = find_json_value(blob, "playlist_snapshot")
    if not isinstance(snapshot, dict):
        print(json.dumps({"ok": False, "reason": "no-snapshot", "path": path}))
        return 0

    raw_tracks = snapshot.get("playlist") or []
    tracks = [normalize(track, i) for i, track in enumerate(raw_tracks)]

    try:
        current = int(snapshot.get("cur_song_index"))
    except (TypeError, ValueError):
        current = -1

    account = find_json_value(blob, "cur_user") or {}
    nickname = str(account.get("nickname") or "").strip()

    print(json.dumps({
        "ok": True,
        "path": path,
        "current": current,
        "tracks": tracks,
        "loggedIn": bool(account.get("user_id")),
        "nickname": nickname,
        "avatarUrl": str(account.get("avatar_url") or "").strip(),
        "updatedAt": str(snapshot.get("playlist_update_at") or ""),
    }, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    sys.exit(main())
