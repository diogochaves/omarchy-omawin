#!/bin/bash
# Copies the stopped Windows VM aside, for chaves.omawin's Back up VM… face.
#
#   helpers/backup.sh plan   ONE line of key=value pairs, every key present:
#                            ok=1 reflink=1 used=24696061952 free=1616073883648
#                            target=.windows.bak-2026-10-04 last=1790812800
#   helpers/backup.sh run    makes that copy: `copied=<bytes>` lines while it
#                            runs, then `done=<name>`; SIGTERM cancels it
#
#   ok       there is room for the copy (1/0)
#   reflink  ~/.windows and $HOME are on one btrfs or XFS filesystem, so the
#            copy shares its blocks and is near instant (1/0)
#   used     bytes ~/.windows occupies on disk (data.img is sparse: this is
#            what Windows has written, not its size)
#   free     bytes free where the copy goes
#   target   the folder `run` would make in $HOME
#   last     mtime, epoch seconds, of the newest earlier backup, or empty
#
# A backup is a folder next to the original, ~/.windows.bak-<date> (-2, -3…
# for a second one that day), holding
#
#   windows/      a copy of everything in ~/.windows, data.img included
#   credentials   a copy of ~/.config/windows/credentials (0600), if there is one
#
# which is what the README's "Restoring a backed-up VM" puts back. It is made
# as the user: everything in ~/.windows is theirs, nothing needs root. The VM
# must be off — a running Windows writes to data.img under the copy — and the
# card only offers this while it is, and blocks Start until it ends.
#
# The copy is `cp -a --reflink=auto --sparse=always`: on btrfs (Omarchy's
# default) or XFS it shares extents and costs nothing until Windows changes
# them; elsewhere it is a full copy of the blocks Windows has written. It goes
# to <target>.partial first and is renamed into place only when complete, and a
# cancelled or failed copy removes the partial folder: there is never a
# half-backup that looks whole.
#
# Room: a full copy needs `used` plus 1 GiB free, a reflink copy 1 GiB for the
# metadata. It is the same drive as the original, which the card says: this
# guards against a bad Tune, update or Remove, not a failed disk.
#
# Environment (all optional, the defaults are the real system):
#   WINDOWS_DIR       the VM's storage      (default ~/.windows)
#   CREDENTIALS_FILE  the login             (default ~/.config/windows/credentials)
#   BACKUP_ROOT       where backups go      (default $HOME)
#   TODAY             the date in the name  (default today, YYYY-MM-DD)
#   FREE_BYTES, REFLINK  override the two readings, for the tests

set -uo pipefail
export LC_ALL=C

windows=${WINDOWS_DIR:-$HOME/.windows}
credentials=${CREDENTIALS_FILE:-$HOME/.config/windows/credentials}
root=${BACKUP_ROOT:-$HOME}
today=${TODAY:-$(/usr/bin/date +%F)}
spare=$((1024 * 1024 * 1024))

die() {
  printf '%s\n' "$*" >&2
  exit 2
}

[[ $today =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] || die "not a date: $today"

# Bytes a path occupies on disk, following nothing outside it.
occupied() {
  local bytes
  bytes=$(/usr/bin/du -s -B1 -x -- "$1" 2>/dev/null | /usr/bin/cut -f1) || return 1
  [[ $bytes =~ ^[0-9]{1,19}$ ]] || return 1
  printf '%s' "$bytes"
}

free_bytes() {
  if [[ -n ${FREE_BYTES-} ]]; then
    printf '%s' "$FREE_BYTES"
    return
  fi
  /usr/bin/df -B1 --output=avail -- "$root" 2>/dev/null | /usr/bin/tail -n 1 | /usr/bin/tr -d ' '
}

# Shared extents need one filesystem that has them, under both paths.
reflinks() {
  if [[ -n ${REFLINK-} ]]; then
    [[ $REFLINK == 1 ]]
    return
  fi
  local type src dst
  type=$(/usr/bin/stat -f -c %T -- "$windows/." 2>/dev/null) || return 1
  [[ $type == btrfs || $type == xfs ]] || return 1
  src=$(/usr/bin/stat -c %d -- "$windows/." 2>/dev/null) || return 1
  dst=$(/usr/bin/stat -c %d -- "$root/." 2>/dev/null) || return 1
  [[ $src == "$dst" ]]
}

# The first free name for today: .windows.bak-<date>, then -2, -3…
target_name() {
  local name=.windows.bak-$today n=2
  while [[ -e $root/$name || -e $root/$name.partial ]]; do
    name=.windows.bak-$today-$n
    ((n++))
    ((n < 100)) || return 1
  done
  printf '%s' "$name"
}

# The newest finished backup's mtime, or nothing.
last_backup() {
  local newest=0 dir when
  for dir in "$root"/.windows.bak-*; do
    [[ -d $dir && $dir != *.partial ]] || continue
    when=$(/usr/bin/stat -c %Y -- "$dir" 2>/dev/null) || continue
    ((when > newest)) && newest=$when
  done
  ((newest > 0)) && printf '%s' "$newest"
}

plan() {
  [[ -d $windows && -f $windows/data.img ]] || die "no VM to back up: $windows has no data.img"
  # "/." so a ~/.windows that is a symlink (Omarchy allows one) is measured
  # where it points, as the copy reads it.
  used=$(occupied "$windows/.") || die "cannot read the size of $windows"
  free=$(free_bytes)
  [[ $free =~ ^[0-9]{1,19}$ ]] || die "cannot read the free space in $root"
  reflink=0
  reflinks && reflink=1
  need=$spare
  ((reflink)) || need=$((used + spare))
  ok=0
  ((free >= need)) && ok=1
  target=$(target_name) || die "too many backups for $today"
}

print_plan() {
  plan
  printf 'ok=%s reflink=%s used=%s free=%s target=%s last=%s\n' \
    "$ok" "$reflink" "$used" "$free" "$target" "$(last_backup)"
}

copy_pid=
partial=

# Cancel, or a failure: stop the copy and take the half-made folder away.
abandon() {
  [[ -n $copy_pid ]] && kill "$copy_pid" 2>/dev/null && wait "$copy_pid" 2>/dev/null
  [[ -n $partial && -d $partial ]] && /usr/bin/rm -rf -- "$partial"
  [[ -n $partial ]] && /usr/bin/rm -f -- "$partial.errors"
  return 0
}

run() {
  plan
  ((ok)) || die "not enough room: the copy needs $(((reflink ? spare : used + spare) / spare)) GB free, $root has $((free / spare)) GB"
  partial=$root/$target.partial
  trap 'abandon; exit 130' TERM INT HUP

  local old_umask errors
  old_umask=$(umask)
  umask 077
  /usr/bin/mkdir -- "$partial" || die "cannot make $partial"
  umask "$old_umask"
  errors=$partial.errors
  /usr/bin/cp -a --reflink=auto --sparse=always -- "$windows/." "$partial/windows" 2>"$errors" &
  copy_pid=$!

  # Progress while it runs; `sleep & wait` so a SIGTERM is acted on at once.
  while kill -0 "$copy_pid" 2>/dev/null; do
    printf 'copied=%s\n' "$(occupied "$partial" || echo 0)"
    /usr/bin/sleep 1 &
    wait $! 2>/dev/null
  done
  local status=0
  wait "$copy_pid" || status=$?
  copy_pid=

  if ((status != 0)); then
    local why
    why=$(/usr/bin/tail -n 1 -- "$errors" 2>/dev/null)
    /usr/bin/rm -f -- "$errors"
    abandon
    die "the copy failed: ${why:-cp exited with status $status}"
  fi
  /usr/bin/rm -f -- "$errors"

  if [[ -f $credentials ]]; then
    /usr/bin/cp -p -- "$credentials" "$partial/credentials" || {
      abandon
      die "could not copy $credentials"
    }
    /usr/bin/chmod 0600 -- "$partial/credentials"
  fi

  /usr/bin/mv -T -- "$partial" "$root/$target" || {
    abandon
    die "could not rename $partial"
  }
  partial=
  trap - TERM INT HUP
  printf 'done=%s\n' "$target"
}

case ${1-} in
  plan) print_plan ;;
  run) run ;;
  *) die "usage: backup.sh plan | run" ;;
esac
