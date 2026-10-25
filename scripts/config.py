#!/usr/bin/env python3
"""Read and minimally edit the two musicfox config keys this plugin cares about.

Why not a TOML round-trip: ~/.config/go-musicfox/config.toml ships as a
docstring in Chinese, with a commented-out key for nearly every setting. Any
library that loads and re-serialises it throws those comments away, and the user
loses a reference document. So this script edits one line in place and leaves
every other byte untouched.

Vocabulary:
  read <path>                     -> {"autoplay": bool, "engine": str}
  set-autoplay <path> <bool>      -> rewrite `[autoplay]`'s `enable`
  set-engine <path> <name>        -> rewrite `[player]`'s `engine`
"""

import json
import os
import re
import sys


def load_text(path):
    with open(path, "r", encoding="utf-8") as handle:
        return handle.read()


def section_bounds(lines, section):
    """Return (header_index, end_index) for a `[section]` table.

    `end_index` is the first line that starts a new table or EOF, so callers can
    search only inside the section they mean — `enable` appears in several
    tables and editing the wrong one would be silent and confusing.
    """
    header = None
    for index, line in enumerate(lines):
        if re.match(r"^\s*\[" + re.escape(section) + r"\]\s*$", line):
            header = index
            break
    if header is None:
        return None, None

    end = len(lines)
    for index in range(header + 1, len(lines)):
        if re.match(r"^\s*\[.+\]\s*$", lines[index]):
            end = index
            break
    return header, end


def find_key(lines, section, key):
    header, end = section_bounds(lines, section)
    if header is None:
        return None
    pattern = re.compile(r"^(\s*)" + re.escape(key) + r"(\s*=\s*)(.*?)(\r?\n)?$")
    for index in range(header + 1, end):
        match = pattern.match(lines[index])
        if match:
            return index
    return None


def bare_value(raw):
    """Strip a TOML value down to its bare token: "mpv" -> mpv, true -> true."""
    value = raw.strip()
    if value.startswith("#"):
        return ""
    # Drop a trailing comment that is not inside quotes.
    if value[:1] in ('"', "'"):
        quote = value[0]
        end = value.find(quote, 1)
        if end < 0:
            return value.strip(quote)
        return value[1:end]
    hash_at = value.find("#")
    if hash_at >= 0:
        value = value[:hash_at]
    return value.strip()


def read_config(path):
    try:
        text = load_text(path)
    except OSError:
        return {"autoplay": False, "engine": "", "ok": False}

    lines = text.splitlines()

    autoplay = False
    index = find_key(lines, "autoplay", "enable")
    if index is not None:
        autoplay = bare_value(lines[index].split("=", 1)[1]).lower() == "true"

    engine = ""
    index = find_key(lines, "player", "engine")
    if index is not None:
        engine = bare_value(lines[index].split("=", 1)[1])

    return {"autoplay": autoplay, "engine": engine, "ok": True}


def write_keys(path, updates):
    """Rewrite `updates` = [(section, key, literal)] preserving everything else."""
    try:
        with open(path, "r", encoding="utf-8") as handle:
            lines = handle.read().splitlines(keepends=True)
    except OSError as error:
        return {"ok": False, "error": str(error)}

    changed = []
    for section, key, literal in updates:
        pattern = re.compile(r"^(\s*" + re.escape(key) + r"\s*=\s*)(.*?)(\r?\n)?$")
        index = find_key(lines, section, key)
        if index is not None:
            match = pattern.match(lines[index].rstrip("\r\n"))
            if match:
                newline = match.group(3) or "\n"
                lines[index] = match.group(1) + literal + newline
                changed.append("{0}.{1}={2}".format(section, key, literal))
            continue

        # Key absent: insert it right after the section header rather than at
        # the end of the file, which would land it in the wrong table.
        header, _ = section_bounds(lines, section)
        if header is None:
            continue
        lines.insert(header + 1, "{0} = {1}\n".format(key, literal))
        changed.append("{0}.{1}={2} (added)".format(section, key, literal))

    if not changed:
        return {"ok": True, "changed": []}

    # Write through a temp file in the same directory so a crash cannot leave a
    # half-written config behind, and keep the original mode.
    temp = path + ".musicfox-control.tmp"
    with open(temp, "w", encoding="utf-8") as handle:
        handle.write("".join(lines))
    os.replace(temp, path)

    return {"ok": True, "changed": changed}


def main(argv):
    if len(argv) < 3:
        print(json.dumps({"ok": False, "error": "usage: config.py <read|set-autoplay|set-engine> <path> [value]"}))
        return 2

    action = argv[1]
    path = argv[2]

    if action == "read":
        print(json.dumps(read_config(path), ensure_ascii=False))
        return 0

    if action in ("set-autoplay", "set-engine"):
        if len(argv) < 4:
            print(json.dumps({"ok": False, "error": "missing value"}))
            return 2
        value = argv[3]
        if action == "set-autoplay":
            literal = "true" if value.lower() in ("true", "1", "yes", "on") else "false"
            updates = [("autoplay", "enable", literal)]
        else:
            updates = [("player", "engine", '"' + value.replace('"', "") + '"')]
        print(json.dumps(write_keys(path, updates), ensure_ascii=False))
        return 0

    print(json.dumps({"ok": False, "error": "unknown action: " + action}))
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv))
