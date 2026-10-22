#!/bin/bash
# The Windows window: bring it forward, or make Windows fill it after a
# connect.
#
# The window is xfreerdp3's, titled "Windows VM - Omarchy" by
# `omarchy-windows-vm launch` (the same /title since Omarchy 3.1).
#
#   rdp-window.sh focus  brings it forward, for a middle click or the key while
#                        a session is up (Start and Connect are off then):
#                        focusing it switches to its workspace. Prints
#                        "focused", or "none" when no such window is open yet.
#   rdp-window.sh fit    makes Windows fill the window once the session is up
#                        (#16). Prints what it did: "fitted", or why not.
#   rdp-window.sh pick   reads `hyprctl clients -j` on stdin and prints the
#                        window's address, or an empty line.
#   rdp-window.sh caps   reads `xprop WM_NORMAL_HINTS` on stdin and prints
#                        "open" or "waiting" (see fit).
#
# Why fit exists: with /dynamic-resolution, Hyprland tiles the window before
# Windows opens its Display Control channel, so xfreerdp sends the window's
# size on its 500 ms resize timer, 0 to 500 ms after Windows' caps PDU.
# Windows ignores a layout that comes within about 120 ms of its caps, and
# xfreerdp never resends one whose size hasn't changed: about half of all
# connects stayed at 1024x768 in the corner of a black window (measured, 12
# connects; diogochaves/upstream#178). So fit waits for the caps, which
# xfreerdp marks by making its window resizable (WM_NORMAL_HINTS from 1x1
# to 320x320 minimum), then widens the window's border by one pixel for
# 0.7 s: a 2-pixel resize that makes xfreerdp send the size again, well
# past that window. On a session that was already right, Windows blanks for
# about 70 ms while it changes resolution.
#
# The dispatches are Omarchy's own: Omarchy 4.5's Lua form first, then, for
# focus, the classic one Hyprland's hyprlang config takes. Exit 0 for every
# outcome but a focus that neither dispatch took. Nothing privileged runs
# here, and the programs are constants.

set -uo pipefail
export LC_ALL=C

title='Windows VM - Omarchy'

pick() {
  /usr/bin/jq -r --arg t "$title" \
    'first(.[]? | select(.title == $t) | .address | select(test("^0x[0-9a-fA-F]+$"))) // ""' \
    2>/dev/null
}

caps() {
  if /usr/bin/grep -q 'minimum size: 320 by 320'; then echo open; else echo waiting; fi
}

window() {
  /usr/bin/hyprctl clients -j 2>/dev/null | pick
}

# hyprctl answers "ok" when a dispatch ran. Under the Lua config a classic
# dispatch fails with exit 7, but the reply is what both configs agree on.
dispatch() {
  [[ $(/usr/bin/hyprctl dispatch "$1" 2>&1) == ok ]]
}

prop() { # address prop value
  dispatch "hl.dsp.window.set_prop({ prop = \"$2\", value = \"$3\", window = \"address:$1\" })"
}

focus() {
  local address reply
  address=$(window)
  if [[ -z $address ]]; then
    echo none
    exit 0
  fi
  reply=$(/usr/bin/hyprctl dispatch "hl.dsp.focus({ window = \"address:$address\" })" 2>&1)
  if [[ $reply != ok ]]; then
    reply=$(/usr/bin/hyprctl dispatch focuswindow "address:$address" 2>&1)
  fi
  if [[ $reply != ok ]]; then
    echo "${reply:0:200}"
    exit 1
  fi
  echo focused
}

fit() {
  local address='' border deadline
  # A Start connects only once Windows has booted far enough to answer.
  deadline=$((SECONDS + 240))
  while ((SECONDS < deadline)); do
    address=$(window)
    [[ -n $address ]] && break
    /usr/bin/sleep 0.5
  done
  if [[ -z $address ]]; then
    echo no-window
    exit 0
  fi

  # The logon comes first: up to 5 s after the window on a fresh boot.
  if [[ -x /usr/bin/xprop ]]; then
    deadline=$((SECONDS + 90))
    until [[ $(/usr/bin/xprop -name "$title" WM_NORMAL_HINTS 2>/dev/null | caps) == open ]]; do
      if ((SECONDS >= deadline)); then
        echo no-caps
        exit 0
      fi
      if [[ -z $(window) ]]; then
        echo gone
        exit 0
      fi
      /usr/bin/sleep 0.25
    done
  else
    /usr/bin/sleep 8
  fi
  # Past xfreerdp's 500 ms resize timer, so the size goes out at once.
  /usr/bin/sleep 0.7

  address=$(window)
  if [[ -z $address ]]; then
    echo gone
    exit 0
  fi
  border=$(/usr/bin/hyprctl getoption general:border_size -j 2>/dev/null | /usr/bin/jq -r '.int // empty' 2>/dev/null)
  [[ $border =~ ^[0-9]{1,3}$ ]] || border=2

  # no_anim: the border and the window snap, rather than tween through
  # several sizes.
  if ! prop "$address" no_anim 1; then
    echo unsupported
    exit 0
  fi
  # A shell reload mid-nudge must not leave the wider border behind.
  trap 'prop "$address" border_size unset; prop "$address" no_anim unset; exit 0' TERM INT HUP
  prop "$address" border_size "$((border + 1))"
  /usr/bin/sleep 0.7
  prop "$address" border_size unset
  prop "$address" no_anim unset
  trap - TERM INT HUP
  echo fitted
}

case ${1:-} in
  focus) focus ;;
  fit) fit ;;
  pick) pick || true ;;
  caps) caps ;;
  *)
    echo "usage: rdp-window.sh focus|fit|pick|caps" >&2
    exit 2
    ;;
esac
