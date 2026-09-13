#!/bin/bash
# Says whether chaves.omawin's polkit rule is installed, for the Settings face.
#
# Prints ONE line of key=value pairs; every key is always present:
#
#   present=1 user=chaves since=1789186123
#   present=0 user= since=
#
#   present  a copy of the installed rule is in the state directory (1/0)
#   user     the user name that copy names, read out of the rule itself
#   since    its mtime in epoch seconds, i.e. when `setup` installed it
#
# Why a copy and not the rule itself: /etc/polkit-1/rules.d is root:polkitd
# 0750, so the user cannot list it, stat it or even `test -f` a file in it, and
# `pkcheck --detail` refuses an unprivileged caller. There is no unprivileged
# way to ask polkit what it would answer. So `sudo ./setup polkit` writes a
# user-owned copy of exactly what it installed at
# $XDG_STATE_HOME/omawin/49-omawin.rules (0644, chowned to the user) and
# deletes it again on `--remove`; this reads that.
#
# It is a record, not the truth: a rule removed by hand leaves the copy behind,
# which is why the card says "as recorded by setup" rather than "installed".
#
# $XDG_STATE_HOME is the widget's own state directory, but `setup` runs as root
# and cannot read the user's environment, so it writes to ~/.local/state/omawin
# — the default. Both are looked at here, in that order, so a user with
# XDG_STATE_HOME pointing elsewhere still gets the right answer.
#
# Environment (optional):
#   OMAWIN_STATE_DIR  where to look first (default $XDG_STATE_HOME/omawin, or
#                     ~/.local/state/omawin)

set -uo pipefail
export LC_ALL=C

rule_name=49-omawin.rules
state_dir=${OMAWIN_STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/omawin}
fallback_dir=$HOME/.local/state/omawin

present=0 user= since=
for dir in "$state_dir" "$fallback_dir"; do
  file=$dir/$rule_name
  [[ -f $file ]] || continue
  present=1
  # The same one line the rule is rendered from: subject.user !== "name".
  user=$(/usr/bin/sed -n 's/.*subject\.user !== "\([^"]*\)".*/\1/p' -- "$file" 2>/dev/null |
    /usr/bin/head -n 1)
  [[ $user =~ ^[a-z_][a-z0-9_-]{0,31}\$?$ ]] || user=
  since=$(/usr/bin/stat -Lc '%Y' -- "$file" 2>/dev/null) || since=
  [[ $since =~ ^[0-9]{1,12}$ ]] || since=
  break
done

printf 'present=%s user=%s since=%s\n' "$present" "$user" "$since"
