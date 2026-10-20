#!/bin/bash
# Copies the stopped Windows VM aside, for chaves.omawin's Back up VM… face.
#
#   helpers/backup.sh plan   ONE line of key=value pairs, every key present,
#                            `where` last (a path may hold spaces):
#                            ok=1 reflink=1 same=1 used=24696061952
#                            free=1616073883648 target=windows.bak-2026-10-04
#                            last=1790812800 where=/mnt/data
#   helpers/backup.sh run    makes that copy: `copied=<bytes>` lines while it
#                            runs, then `done=<full path>`; SIGTERM cancels it
#   helpers/backup.sh list   one line per backup on disk, newest first:
#                            when=1792504162 own=0 measured=btrfs same=1
#                            path=/mnt/data/windows.bak-2026-10-20
#
#   ok       there is room for the copy (1/0)
#   reflink  the VM's folder and `where` are on one btrfs or XFS filesystem,
#            so the copy shares its blocks and is near instant (1/0); see "+C"
#   same     `where` is on the same filesystem as the VM's folder (1/0): the
#            copy undoes a bad Tune, update or Remove, but dies with that drive
#   used     bytes ~/.windows occupies on disk (data.img is sparse: this is
#            what Windows has written, not its size)
#   free     bytes free where the copy goes
#   target   the folder `run` would make in `where`
#   last     mtime, epoch seconds, of the newest earlier backup, or empty
#   where    the folder the backup goes in (see "Where" below)
#
# `list` fields, `path` last (it may hold spaces):
#   when      the backup's mtime, epoch seconds
#   own       bytes only it holds, what deleting it frees: btrfs's exclusive
#             size where the filesystem shares blocks (`measured=btrfs`), else
#             its plain size (`measured=du`)
#   same      on the VM's filesystem (1/0)
#   path      the backup folder
# A backup is a <name>.bak-<date> folder holding windows/data.img, beside the
# VM's folder or in $HOME; half-made `.partial` folders are not listed.
#
# Where: beside the VM's real folder, so on its filesystem and a reflink copy
# wherever it allows one. ~/.windows is usually that folder, and the backup is
# ~/.windows.bak-<date>; Omarchy allows ~/.windows to be a symlink, often to a
# bigger drive, and then it goes beside where it points (/mnt/data/windows ->
# /mnt/data/windows.bak-<date>). A folder there that isn't writable, or a name
# that isn't plain, falls back to $HOME and .windows.bak-<date>, and `same`
# says whether that is another drive. `last` counts backups in both places.
#
# Exit status 3, from either: nothing to back up yet. A VM counts as installed
# once its compose file and login exist, but dockur makes data.img only on
# Windows' first start, so a VM that never started has no disk to copy. Any
# other failure is status 2, with the reason on stderr.
#
# A backup is a folder next to the original, <name>.bak-<date> (-2, -3… for a
# second one that day), holding
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
# +C: dockur makes data.img with `chattr +C` (no copy-on-write, no checksums),
# and btrfs shares extents only between files that agree on it. A plain copy
# of a +C image is quietly a full one, so when data.img is +C the empty
# <target>.partial is made +C too: what cp creates in it inherits that, and
# the copy shares its blocks (and keeps copy-on-write off, as the VM expects).
# A folder that refuses +C means a full copy after all: `run` then checks the
# room for one. On btrfs, an image whose flags can't be read is not counted
# on to share.
#
# Room: a full copy needs `used` plus 1 GiB free, a reflink copy 1 GiB for the
# metadata. It is the same drive as the original, which the card says: this
# guards against a bad Tune, update or Remove, not a failed disk.
#
# Environment (all optional, the defaults are the real system):
#   WINDOWS_DIR       the VM's storage      (default ~/.windows)
#   CREDENTIALS_FILE  the login             (default ~/.config/windows/credentials)
#   BACKUP_ROOT       where backups go      (default: see "Where" above)
#   TODAY             the date in the name  (default today, YYYY-MM-DD)
#   FREE_BYTES, REFLINK  override the two readings, for the tests
#   NOCOW, NOCOW_SET     override whether data.img is +C and whether the
#                        partial folder takes +C (1/0), for the tests

set -uo pipefail
export LC_ALL=C

windows=${WINDOWS_DIR:-$HOME/.windows}
credentials=${CREDENTIALS_FILE:-$HOME/.config/windows/credentials}
root=
base=.windows
today=${TODAY:-$(/usr/bin/date +%F)}
spare=$((1024 * 1024 * 1024))

die() {
  printf '%s\n' "$*" >&2
  exit 2
}

nothing_yet() {
  printf '%s\n' "$*" >&2
  exit 3
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

# data.img's +C: 0 when it has it, 1 when not, 2 when its flags can't be read.
source_nocow() {
  if [[ -n ${NOCOW-} ]]; then
    [[ $NOCOW == 1 ]]
    return
  fi
  local flags
  flags=$(/usr/bin/lsattr -d -- "$windows/data.img" 2>/dev/null) || return 2
  [[ ${flags%% *} == *C* ]]
}

# +C on the empty folder the copy goes into, so what cp makes there has it.
set_nocow() {
  if [[ -n ${NOCOW_SET-} ]]; then
    [[ $NOCOW_SET == 1 ]]
    return
  fi
  /usr/bin/chattr +C -- "$1" 2>/dev/null
}

# Shared extents need one filesystem that has them, under both paths. On
# btrfs they also need data.img's +C known, so the copy can match it.
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
  [[ $src == "$dst" ]] || return 1
  [[ $type == btrfs ]] || return 0
  source_nocow
  (($? != 2))
}

# Where the backup goes, and its name's stem: beside the VM's real folder when
# that is writable and plainly named, else $HOME as .windows.
choose_root() {
  if [[ -n ${BACKUP_ROOT-} ]]; then
    root=$BACKUP_ROOT
    return
  fi
  root=$HOME
  base=.windows
  local real parent name
  real=$(/usr/bin/realpath -e -- "$windows" 2>/dev/null) || return 0
  parent=${real%/*}
  name=${real##*/}
  [[ -n $parent && $parent != *$'\n'* && -d $parent && -w $parent ]] || return 0
  [[ $name =~ ^\.?[A-Za-z0-9_][A-Za-z0-9._-]{0,63}$ ]] || return 0
  root=$parent
  base=$name
}

# The first free name for today: <base>.bak-<date>, then -2, -3…
target_name() {
  local name=$base.bak-$today n=2
  while [[ -e $root/$name || -e $root/$name.partial ]]; do
    name=$base.bak-$today-$n
    ((n++))
    ((n < 100)) || return 1
  done
  printf '%s' "$name"
}

# The newest finished backup's mtime, here or in $HOME (where earlier
# versions put them all), or nothing.
last_backup() {
  local newest=0 dir when
  for dir in "$root/$base".bak-* "$HOME"/.windows.bak-*; do
    [[ -d $dir && $dir != *.partial ]] || continue
    when=$(/usr/bin/stat -c %Y -- "$dir" 2>/dev/null) || continue
    ((when > newest)) && newest=$when
  done
  ((newest > 0)) && printf '%s' "$newest"
}

# What a backup holds that nothing else does, and how that was measured:
# "<bytes> btrfs" from btrfs's exclusive count, "<bytes> du" otherwise.
own_size() {
  local line bytes
  if [[ $(/usr/bin/stat -f -c %T -- "$1" 2>/dev/null) == btrfs && -x /usr/bin/btrfs ]]; then
    line=$(/usr/bin/btrfs filesystem du -s --raw -- "$1" 2>/dev/null | /usr/bin/tail -n 1)
    read -r _ bytes _ <<<"$line"
    if [[ $bytes =~ ^[0-9]{1,19}$ ]]; then
      printf '%s btrfs' "$bytes"
      return
    fi
  fi
  bytes=$(occupied "$1") || return 1
  printf '%s du' "$bytes"
}

# Every backup on disk, beside the VM's folder and in $HOME, newest first.
backups() {
  local dir seen=
  for dir in "$root/$base".bak-* "$HOME"/.windows.bak-*; do
    [[ $dir == *.partial || ! -d $dir || -L $dir || ! -f $dir/windows/data.img ]] && continue
    [[ $dir == *$'\n'* ]] && continue
    [[ $seen == *$'\n'"$dir"$'\n'* ]] && continue
    seen+=$'\n'"$dir"$'\n'
    printf '%s\t%s\n' "$(/usr/bin/stat -c %Y -- "$dir" 2>/dev/null || echo 0)" "$dir"
  done | /usr/bin/sort -rn -k1,1
}

print_list() {
  [[ -d $windows ]] || nothing_yet "nothing to list: there is no $windows"
  choose_root
  local when dir own measured same vm
  vm=$(/usr/bin/stat -c %d -- "$windows/." 2>/dev/null)
  while IFS=$'\t' read -r when dir; do
    read -r own measured <<<"$(own_size "$dir" || echo "")"
    same=0
    [[ -n $vm && $(/usr/bin/stat -c %d -- "$dir" 2>/dev/null) == "$vm" ]] && same=1
    printf 'when=%s own=%s measured=%s same=%s path=%s\n' "$when" "$own" "$measured" "$same" "$dir"
  done < <(backups)
}

# The copy and the VM's folder on one filesystem.
same_drive() {
  local src dst
  src=$(/usr/bin/stat -c %d -- "$windows/." 2>/dev/null) || return 1
  dst=$(/usr/bin/stat -c %d -- "$root/." 2>/dev/null) || return 1
  [[ $src == "$dst" ]]
}

plan() {
  [[ -d $windows && -f $windows/data.img ]] ||
    nothing_yet "nothing to back up yet: $windows has no data.img until Windows first starts"
  choose_root
  # "/." so a ~/.windows that is a symlink (Omarchy allows one) is measured
  # where it points, as the copy reads it.
  used=$(occupied "$windows/.") || die "cannot read the size of $windows"
  free=$(free_bytes)
  [[ $free =~ ^[0-9]{1,19}$ ]] || die "cannot read the free space in $root"
  nocow=0
  source_nocow && nocow=1
  reflink=0
  reflinks && reflink=1
  same=0
  same_drive && same=1
  need=$spare
  ((reflink)) || need=$((used + spare))
  ok=0
  ((free >= need)) && ok=1
  target=$(target_name) || die "too many backups for $today"
}

print_plan() {
  plan
  printf 'ok=%s reflink=%s same=%s used=%s free=%s target=%s last=%s where=%s\n' \
    "$ok" "$reflink" "$same" "$used" "$free" "$target" "$(last_backup)" "$root"
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
  # A folder that won't take +C can't share a +C image's blocks: the copy is
  # a full one, which needs the room for it.
  if ((nocow)) && ! set_nocow "$partial" && ((reflink)); then
    reflink=0
    ((free >= used + spare)) || {
      abandon
      die "not enough room: $partial can't turn copy-on-write off, so the copy is a full one and needs $(((used + spare) / spare)) GB free, $root has $((free / spare)) GB"
    }
  fi
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
  printf 'done=%s\n' "$root/$target"
}

case ${1-} in
  plan) print_plan ;;
  run) run ;;
  list) print_list ;;
  *) die "usage: backup.sh plan | run | list" ;;
esac
