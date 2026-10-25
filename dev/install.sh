#!/usr/bin/env bash
# Install the plugin into the Omarchy shell and enable it on the bar.
#
# The shell rejects symlinked plugin folders (omarchy-plugin-validate refuses
# any symlink inside the directory), so development means copying the working
# tree over the installed one. Run this after every edit; plugin QML hot-reloads
# once the files change.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
target="${HOME}/.config/omarchy/plugins/io.github.musicfox.control"
shell_json="${HOME}/.config/omarchy/shell.json"

mkdir -p "$target"
rsync -a --delete --exclude='.git' --exclude='dev' "$here/" "$target/"
echo "synced -> $target"

omarchy plugin validate "$target"
echo "manifest valid"

# Register the panel kind so the shell will load Panel.qml when summoned.
# bar-widget alone is enough to draw the bar entry, but the panel entry point is
# only mounted for plugins that declare a panel-ish kind AND appear in plugins[].
python3 - "$shell_json" <<'PY'
import json, sys

path = sys.argv[1]
with open(path) as handle:
    config = json.load(handle)

plugin_id = "io.github.musicfox.control"
changed = False

layout = config.setdefault("bar", {}).setdefault("layout", {})

# Default placement is the left section, matching the manifest's defaultSection.
# The widget's label scrolls, so it wants room next to the menu/workspaces
# rather than squeezing into center's clock cluster.
placement = "left"

# If a previous run put it elsewhere, move it instead of leaving a duplicate.
for section in ("left", "center", "right"):
    entries = layout.get(section)
    if not isinstance(entries, list):
        continue
    for entry in list(entries):
        if entry.get("id") == plugin_id and section != placement:
            entries.remove(entry)
            changed = True

left = layout.setdefault(placement, [])
if not any(entry.get("id") == plugin_id for entry in left):
    left.append({"id": plugin_id})
    changed = True

plugins = config.setdefault("plugins", [])
if not any(entry.get("id") == plugin_id for entry in plugins):
    plugins.append({"id": plugin_id})
    changed = True

if changed:
    with open(path, "w") as handle:
        json.dump(config, handle, indent=2, ensure_ascii=False)
        handle.write("\n")
    print("updated shell.json")
else:
    print("shell.json already configured")
PY

echo
echo "Now: omarchy restart shell   (shell.json edits hot-reload, kind changes may not)"
