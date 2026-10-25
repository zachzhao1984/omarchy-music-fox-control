#!/usr/bin/env bash
# Attach to the plugin's musicfox tmux session in a real terminal window.
#
# Why this exists instead of `tmux switch-client`: the plugin launches musicfox
# in a *detached* session so the bar is not hijacked by a terminal. A detached
# session has no attached client, so `switch-client` fails with "no current
# client" and the user sees nothing happen. Attaching requires a new terminal,
# which is what Omarchy's own omarchy-launch-terminal-tmux does too.
#
# Usage: mf-attach <session>   (default: musicfox)
set -euo pipefail

session="${1:-musicfox}"

# If the session is already attached somewhere, focus that window instead of
# opening a second view of the same TUI (tmux would mirror keystrokes into both,
# which makes the player unusable).
if tmux list-clients -t "$session" 2>/dev/null | grep -q .; then
  # Nothing sensible to focus from here without window-manager cooperation, so
  # just say so rather than opening a duplicate.
  notify-send -a Musicfox "musicfox is already attached" \
    "Its window is already on screen." 2>/dev/null || true
  exit 0
fi

if ! tmux has-session -t "$session" 2>/dev/null; then
  notify-send -a Musicfox "musicfox is not running" "" 2>/dev/null || true
  exit 1
fi

exec tmux attach -t "$session"
