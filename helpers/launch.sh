#!/bin/bash
# Starts (or reconnects to) the Omarchy Windows VM for chaves.omawin.
#
# `omarchy-windows-vm launch -k` blocks for the whole RDP session: it runs
# `priv up_wait` and then keeps xfreerdp3 in the foreground. It must therefore
# NOT be a child of the bar — a shell reload would take the RDP window with
# it — and it must not be a plain `uwsm app` either (a scope: still blocking,
# output under a random unit name). So it goes into a named transient user
# service and this script returns at once.
#
#   started         the unit was created; the widget now polls
#                   `systemctl --user is-active omawin-launch` and reads the
#                   outcome back with helpers/launch-result.sh
#   already-running a unit of that name is already alive, i.e. an RDP session
#                   is already up or coming. A no-op, NOT an error: Start and
#                   Connect are the same command and pressing either twice
#                   must not paint the widget red.
#
# --collect makes systemd forget the unit the moment it exits, so nothing has
# to be reset before the next launch; --property=ExitType=cgroup keeps the
# unit alive until every process it forked is gone, which is what makes
# is-active a usable "the session is over" signal. The environment
# (WAYLAND_DISPLAY, HYPRLAND_INSTANCE_SIGNATURE, DISPLAY) is already in the
# user manager because uwsm imports it there, and `launch` needs all three.
#
# Exit 0 with one of the two words above on stdout; exit 1 with systemd-run's
# own message on stdout when anything else went wrong. Nothing privileged runs
# here: the pkexec call is inside omarchy-windows-vm.
#
# Environment (optional):
#   OMAWIN_UNIT         unit name          (default omawin-launch)
#   OMAWIN_LAUNCH_CMD   command to run     (default omarchy-windows-vm launch -k)

set -uo pipefail
export LC_ALL=C

unit=${OMAWIN_UNIT:-omawin-launch}
read -r -a cmd <<<"${OMAWIN_LAUNCH_CMD:-omarchy-windows-vm launch -k}"

message=$(systemd-run --user "--unit=$unit" --collect --quiet \
  --property=ExitType=cgroup \
  -- "${cmd[@]}" 2>&1)
status=$?

if [[ $status -eq 0 ]]; then
  echo started
  exit 0
fi

# systemd has worded this two ways: "Unit omawin-launch.service already
# exists." on older releases and "Unit omawin-launch.service was already
# loaded or has a fragment file." on 261 (what this box prints). Match on the
# unit name plus "already", which covers both, and let any other wording
# downgrade to a plain failure rather than to a silent success.
if [[ $message == *"$unit"*already* ]]; then
  echo already-running
  exit 0
fi

echo "${message:-systemd-run failed with status $status}"
exit 1
