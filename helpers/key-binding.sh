#!/bin/bash
# Says which key, if any, runs chaves.omawin's `primary` (Start, or Connect),
# for the stopped card, Settings and the tooltip.
#
# Prints ONE line: the key as Omarchy writes it, "SUPER + ALT + W", or an
# empty line when there is none.
#
# A plugin cannot register a key binding; the user adds a line like
#
#   o.bind("SUPER + ALT + W", "Windows VM", "omarchy-shell chaves.omawin primary")
#
# to ~/.config/hypr/bindings.lua. This reads that file as text and looks only
# for such a line: not a comment, a `bind(` whose first argument is a quoted
# key, and `chaves.omawin primary` further along. The file is never run (it is
# Lua, and the user's), and nothing else in it is looked at. `hyprctl binds`
# cannot answer this: under Omarchy's Lua config it lists a function id, not
# the command a key runs.
#
# The last matching line wins, the way a later bind overrides an earlier one.
# A key that is not plain modifier and key names is not printed.
#
# Environment (optional):
#   HYPR_BINDINGS  the file to read (default ~/.config/hypr/bindings.lua)

set -uo pipefail
export LC_ALL=C

file=${HYPR_BINDINGS:-$HOME/.config/hypr/bindings.lua}
bind_line='^[[:space:]]*[A-Za-z_.]*bind[[:space:]]*\([[:space:]]*"([^"]{1,64})"'

key=
if [[ -f $file ]]; then
  while IFS= read -r line || [[ -n $line ]]; do
    [[ $line == *chaves.omawin\ primary* ]] || continue
    [[ $line =~ $bind_line ]] || continue
    raw=${BASH_REMATCH[1]^^}
    parts=() ok=1
    IFS='+' read -ra pieces <<<"$raw"
    for piece in "${pieces[@]}"; do
      piece=${piece//[[:space:]]/}
      [[ $piece =~ ^[A-Z0-9_]{1,16}$ ]] || { ok=0; break; }
      parts+=("$piece")
    done
    ((ok && ${#parts[@]} > 0)) || continue
    key=${parts[0]}
    for piece in "${parts[@]:1}"; do key+=" + $piece"; done
  done < <(/usr/bin/head -c 262144 -- "$file" 2>/dev/null)
fi

printf '%s\n' "$key"
