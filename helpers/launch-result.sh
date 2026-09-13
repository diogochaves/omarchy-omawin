#!/bin/bash
# Reads back how the omawin-launch unit ended, for chaves.omawin.
#
# Prints exactly one line and always exits 0:
#
#   ok                            the launcher finished (or is still running)
#                                 without failing
#   <anything else>               the failure text to show on the failed card
#
# Why it is not just `systemctl show -p Result`: the unit is created with
# --collect, so systemd forgets it the instant it exits, and `show` on a unit
# that is gone answers with the DEFAULTS — Result=success, ExecMainStatus=0 —
# which is indistinguishable from a clean run. Verified on this box (systemd
# 261): LoadState=not-found together with Result=success. So `show` is only
# trusted while the unit still exists; once it is collected the journal is the
# only record, queried by unit name (which matches both systemd's own
# bookkeeping lines and the unit's stdout/stderr) with an explicit
# _SYSTEMD_USER_UNIT= query as a fallback.
#
# Only the LAST run is considered: the window starts at the last "Started …"
# line systemd logged, so a failure from an hour ago cannot resurface after a
# clean launch. A run failed when that window carries systemd's "Failed with
# result" or a non-zero "Main process exited, code=…, status=N".
#
# The message is the launcher's OWN last non-empty line (`omarchy-windows-vm:
# refusing an unsafe VM mount anchor`, xfreerdp's error, gum's), because that
# is what the user can act on; systemd's epilogue is used only when the unit
# printed nothing, and a synthetic "<unit> exited with status N" only when the
# journal has nothing at all (journald rotated it away, or is not running).
#
# The unit name is a constant, the journal window is the last 60 lines capped
# at 64 KiB, and the line printed is capped at 300 characters: whatever the
# launcher or xfreerdp wrote, the card gets one bounded line of it.

set -uo pipefail
export LC_ALL=C

unit=omawin-launch
lines=60

# --- while the unit still exists, systemd's own answer is authoritative -----

mapfile -t props < <(/usr/bin/systemctl --user show \
  -p LoadState -p ActiveState -p Result -p ExecMainStatus --value "$unit" 2>/dev/null)
load=${props[0]:-not-found}
active=${props[1]:-inactive}
result=${props[2]:-success}
mainstatus=${props[3]:-0}

if [[ $load != "not-found" ]]; then
  # Still going: nothing has failed yet.
  [[ $active == "active" || $active == "activating" || $active == "reloading" ]] && { echo ok; exit 0; }
  [[ $result == "success" && $mainstatus == "0" ]] && { echo ok; exit 0; }
fi

# --- otherwise reconstruct the last run from the journal --------------------

journal=$(/usr/bin/journalctl --user -u "$unit" -n "$lines" -o cat --no-pager 2>/dev/null | /usr/bin/head -c 65536)
[[ -z ${journal//[[:space:]]/} ]] &&
  journal=$(/usr/bin/journalctl --user "_SYSTEMD_USER_UNIT=$unit.service" -n "$lines" -o cat --no-pager 2>/dev/null | /usr/bin/head -c 65536)

mapfile -t all <<<"$journal"

# Keep only the lines of the most recent run.
window=()
start=0
for i in "${!all[@]}"; do
  [[ ${all[$i]} == Started\ * ]] && start=$i
done
for ((i = start; i < ${#all[@]}; i++)); do window+=("${all[$i]}"); done

failed=0
status=$mainstatus
for line in "${window[@]}"; do
  if [[ $line == *"Failed with result"* || $line == *"code=killed"* ]]; then
    failed=1
  elif [[ $line =~ Main\ process\ exited,\ code=[a-z]+,\ status=([0-9]+) ]]; then
    if [[ ${BASH_REMATCH[1]} != "0" ]]; then
      failed=1
      status=${BASH_REMATCH[1]}
    fi
  fi
done

# The unit is gone and nothing in its journal says it failed: a clean exit
# (dockur's "windows started successfully", xfreerdp closing normally, or the
# whole record already rotated away — none of which is a failure to report).
if [[ $failed -eq 0 ]]; then
  echo ok
  exit 0
fi

# Prefer the launcher's own words; fall back to systemd's, then to a synthetic
# line so the card is never blank.
message=""
fallback=""
for ((i = ${#window[@]} - 1; i >= 0; i--)); do
  line=${window[$i]}
  line=${line#"${line%%[![:space:]]*}"}
  line=${line%"${line##*[![:space:]]}"}
  [[ -z $line ]] && continue
  [[ -z $fallback ]] && fallback=$line
  [[ $line == "$unit.service:"* || $line == Started\ * || $line == Stopped\ * ]] && continue
  # The launcher's own epilogue after a failed `priv up_wait` is two lines of
  # boilerplate ("❌ Failed to start Windows VM!", "Try checking: …"); the line
  # the user can act on is whatever the root side printed just before them —
  # "refusing an unsafe VM mount anchor", pkexec's "Not authorized". Keep the
  # headline as the answer only when nothing preceded it.
  [[ $line == Try\ checking:* || $line == Starting\ Windows\ VM* ]] && continue
  if [[ $line == *"Failed to start Windows VM"* ]]; then
    [[ -z $message ]] && message="Failed to start Windows VM"
    continue
  fi
  message=$line
  break
done

message=${message:-${fallback:-$unit exited with status $status}}
printf '%s\n' "${message:0:300}"
