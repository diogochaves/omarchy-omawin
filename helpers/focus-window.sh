#!/bin/bash
# Brings the open Windows window forward, for a middle click or the key while
# an RDP session is up: Start and Connect are off then, and the one-click
# shortcut should still do what a launcher does for an app already running.
#
# The window is xfreerdp3's, titled "Windows VM - Omarchy" by
# `omarchy-windows-vm launch` (the same /title since Omarchy 3.1). Focusing it
# switches to its workspace. The dispatch is Omarchy's own from
# omarchy-launch-or-focus: Omarchy 4.5's Lua form first, then the classic one
# Hyprland's hyprlang config takes.
#
#   focus-window.sh        prints "focused", or "none" when no such window is
#                          open yet (the session is still connecting)
#   focus-window.sh pick   reads `hyprctl clients -j` on stdin and prints the
#                          window's address, or an empty line; what the tests
#                          check
#
# Exit 0 for both: a session with no window yet is not an error. Exit 1, with
# hyprctl's reply, only when neither dispatch was taken. Nothing privileged
# runs here, and the programs are constants.

set -uo pipefail
export LC_ALL=C

title='Windows VM - Omarchy'

pick() {
  /usr/bin/jq -r --arg t "$title" \
    'first(.[]? | select(.title == $t) | .address | select(test("^0x[0-9a-fA-F]+$"))) // ""' \
    2>/dev/null
}

if [[ ${1:-} == pick ]]; then
  pick
  exit 0
fi

address=$(/usr/bin/hyprctl clients -j 2>/dev/null | pick)
if [[ -z $address ]]; then
  echo none
  exit 0
fi

# hyprctl answers "ok" when a dispatch ran. Under the Lua config a classic
# dispatch fails with exit 7, but the reply is what both configs agree on.
reply=$(/usr/bin/hyprctl dispatch "hl.dsp.focus({ window = \"address:$address\" })" 2>&1)
if [[ $reply != ok ]]; then
  reply=$(/usr/bin/hyprctl dispatch focuswindow "address:$address" 2>&1)
fi
if [[ $reply != ok ]]; then
  echo "${reply:0:200}"
  exit 1
fi
echo focused
