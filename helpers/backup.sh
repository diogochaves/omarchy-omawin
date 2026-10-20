#!/bin/bash
# Copies the stopped Windows VM aside, for chaves.omawin's Back up VM… face.
#
#   helpers/backup.sh plan   ONE line of key=value pairs, every key present,
#                            `where` last (a path may hold spaces):
#                            ok=1 reflink=1 same=1 used=24696061952
#                            free=1616073883648 target=windows.bak-2026-10-04
#                            last=1790812800 where=/mnt/data
#   helpers/backup.sh run [--cores N --ram NG]
#                            makes that copy: `copied=<bytes>` lines while it
#                            runs, then `done=<full path>`; SIGTERM cancels it.
#                            The cores and RAM given are kept in it, for a
#                            restore after Remove VM
#   helpers/backup.sh list   one line per backup on disk, newest first, VM or
#                            not:
#                            when=1792504162 own=0 measured=btrfs same=1
#                            disk=64G cores=4 ram=8G
#                            path=/mnt/data/windows.bak-2026-10-20
#   helpers/backup.sh delete PATH
#                            deletes that backup, and only a folder `list`
#                            shows: `deleted=<path>`
#   helpers/backup.sh restore PATH --cores N --ram NG --disk NG
#                            puts that backup back as the VM (see "Restore"
#                            below, and "Restore after Remove VM" when there
#                            is no VM): `step=` and `copied=` lines while it
#                            works, `done=<safety backup>` once that is made,
#                            `composed=<cores> <ram> <disk>` if it rewrote the
#                            compose, then `restored=<path>`; SIGTERM cancels
#                            it while it copies
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
#   same      on the VM's filesystem (1/0); 0 when there is no VM
#   disk      its data.img's apparent size, 64G, or empty
#   cores ram the shape it was made with, when it kept one, else empty
#   path      the backup folder
# A backup is a <name>.bak-<date> folder holding windows/data.img, beside the
# VM's folder, in $HOME, in a folder an earlier backup went to (kept in
# $XDG_STATE_HOME/omawin/backup-places, so they are still found once Remove
# VM has taken the ~/.windows link that pointed there), or at the top of a
# mounted drive (/mnt/*, /media/$USER/*, /run/media/$USER/*). Half-made
# `.partial` folders are not listed.
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
#   shape         CORES= and RAM= lines, the shape the VM had, when the card
#                 knew it
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
# Restore, VM off, in an order where stopping half-way never leaves a VM that
# is neither the old one nor the backup:
#
#   1. a safety backup of the VM as it is, exactly as `run` makes one, so a
#      restore can itself be undone (instant where `run` is)
#   2. the backup's windows/ copied into a hidden folder beside the VM's real
#      folder, +C when its data.img is, so on btrfs it shares the backup's
#      blocks. The VM is untouched so far, and Cancel removes this copy
#   3. the swap, keeping the VM's folder itself (Omarchy pins it by device
#      and inode and checks that on every start): its entries renamed out to
#      a hidden folder beside it, the staged ones renamed in
#   4. only when the backup's login or disk size differs, the compose
#      rewritten through `pkexec omarchy-windows-vm __priv write_compose`,
#      the one dialog Tune and Login's Save ask, with the backup's login and
#      disk; a dismissed dialog or a failure swaps the VM's own files back,
#      so nothing has changed (the safety backup stays, in the list)
#   5. the old files deleted (step 1 holds them), and the backup's
#      credentials file back as ~/.config/windows/credentials, 0600,
#      atomically, when it has one
#
# The password is read from the backup's file and piped to pkexec, never an
# argument. The card passes the cores, RAM and disk the next start would use,
# as Login's Save does: write_compose takes all six fields.
#
# Restore after Remove VM, when there is no compose: nothing is there to
# save, so no safety backup, and the backup goes back where it was made, by
# its name (/mnt/data/windows.bak-2026-10-20 to /mnt/data/windows,
# ~/.windows.bak-2026-10-04 to ~/.windows). That folder must be empty or
# missing. When it isn't ~/.windows itself, ~/.windows becomes a link to it
# again, as it was (Remove deletes the link): an empty folder there is
# replaced, anything else refuses.
#
#   1. the backup's windows/ copied into a hidden folder beside where it goes,
#      then moved in
#   2. ~/.windows linked there when it has to be, and ~/Windows (the Shared
#      folder) made if Remove took it
#   3. the compose written, always (the one dialog), with the backup's login
#      and disk and the cores and RAM the card passes; a dismissed dialog or
#      a failure takes all of it away again, the backup untouched
#   4. the credentials file and the launcher's Windows entry, as Install
#      writes them
#
# Omarchy's image is fetched again by the first Start, as Remove deleted it.
#
# Environment (all optional, the defaults are the real system):
#   WINDOWS_DIR       the VM's storage      (default ~/.windows)
#   CREDENTIALS_FILE  the login             (default ~/.config/windows/credentials)
#   BACKUP_ROOT       where backups go      (default: see "Where" above)
#   TODAY             the date in the name  (default today, YYYY-MM-DD)
#   FREE_BYTES, REFLINK  override the two readings, for the tests
#   VM_RUNNING        =1/0 instead of asking vm-state.sh, for the tests
#   COMPOSE_FILE, LEGACY_COMPOSE_FILE  Omarchy's compose, whose presence
#                     means a VM is installed (defaults as vm-state.sh's)
#   SHARED_DIR        the Shared folder     (default ~/Windows)
#   APPS_DIR          the launcher entries  (default ~/.local/share/applications)
#   BACKUP_PLACES     the record of folders backups went to
#   BACKUP_SEARCH     the drives' folders to look in, space-separated, instead
#                     of /mnt/*, /media/$USER/*, /run/media/$USER/*
#   TZ_NAME           skip timedatectl, use this value
#   RESTORE_DRY_RUN   =1 skips the pkexec step and says what it would write;
#                     =dismiss answers as a dismissed dialog would
#   NOCOW, NOCOW_SET     override whether data.img is +C and whether the
#                        partial folder takes +C (1/0), for the tests

set -uo pipefail
export LC_ALL=C

windows=${WINDOWS_DIR:-$HOME/.windows}
credentials=${CREDENTIALS_FILE:-$HOME/.config/windows/credentials}
compose_file=${COMPOSE_FILE:-/var/lib/omarchy/windows/docker-compose.yml}
legacy_compose=${LEGACY_COMPOSE_FILE:-$HOME/.config/windows/docker-compose.yml}
shared=${SHARED_DIR:-$HOME/Windows}
apps=${APPS_DIR:-$HOME/.local/share/applications}
places=${BACKUP_PLACES:-${XDG_STATE_HOME:-$HOME/.local/state}/omawin/backup-places}
shape_cores=
shape_ram=
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

# A folder backups went to, kept so they are found after Remove VM has
# deleted the ~/.windows link that led there. Best effort: a record that
# can't be written loses nothing but that.
remember_place() {
  local dir=$1
  [[ $dir == /* && $dir != *$'\n'* && -d $dir ]] || return 0
  /usr/bin/grep -qxF -- "$dir" "$places" 2>/dev/null && return 0
  /usr/bin/mkdir -p -- "${places%/*}" 2>/dev/null &&
    printf '%s\n' "$dir" >>"$places" 2>/dev/null
  return 0
}

# The folders a backup can be in: beside the VM, $HOME, the recorded ones,
# and the top of each mounted drive.
search_dirs() {
  local -a drives
  printf '%s\n' "$root" "$HOME"
  [[ -f $places ]] && /usr/bin/head -n 50 -- "$places"
  if [[ -n ${BACKUP_SEARCH+x} ]]; then
    read -ra drives <<<"$BACKUP_SEARCH"
  else
    drives=(/mnt/* /media/"${USER-}"/* /run/media/"${USER-}"/*)
  fi
  printf '%s\n' "${drives[@]}"
}

# Every backup on disk, newest first: a <name>.bak-<date> folder holding
# windows/data.img, in one of those folders.
backups() {
  local place dir seen=
  while IFS= read -r place; do
    [[ $place == /* && -d $place ]] || continue
    for dir in "$place"/*.bak-* "$place"/.*.bak-*; do
      [[ ${dir##*/} =~ ^\.?[A-Za-z0-9_][A-Za-z0-9._-]{0,63}\.bak-[0-9]{4}-[0-9]{2}-[0-9]{2}(-[0-9]{1,2})?$ ]] || continue
      [[ ! -d $dir || -L $dir || ! -f $dir/windows/data.img ]] && continue
      dir=${dir//\/\//\/}
      [[ $seen == *$'\n'"$dir"$'\n'* ]] && continue
      seen+=$'\n'"$dir"$'\n'
      printf '%s\t%s\n' "$(/usr/bin/stat -c %Y -- "$dir" 2>/dev/null || echo 0)" "$dir"
    done
  done < <(search_dirs) | /usr/bin/sort -rn -k1,1
}

# One field of a backup's shape file, if it kept a valid one.
shape_of() {
  local value
  value=$(credential_of "$1/shape" "$2") || return 0
  case $2 in
    CORES) [[ $value =~ ^[0-9]{1,2}$ ]] && ((10#$value >= 1)) && printf '%s' "$value" ;;
    RAM) [[ $value =~ ^[0-9]{1,3}G$ ]] && printf '%s' "$value" ;;
  esac
  return 0
}

print_list() {
  choose_root
  [[ -d $windows ]] && remember_place "$root"
  local when dir own measured same vm=
  [[ -d $windows ]] && vm=$(/usr/bin/stat -c %d -- "$windows/." 2>/dev/null)
  while IFS=$'\t' read -r when dir; do
    read -r own measured <<<"$(own_size "$dir" || echo "")"
    same=0
    [[ -n $vm && $(/usr/bin/stat -c %d -- "$dir" 2>/dev/null) == "$vm" ]] && same=1
    printf 'when=%s own=%s measured=%s same=%s disk=%s cores=%s ram=%s path=%s\n' \
      "$when" "$own" "$measured" "$same" "$(image_disk "$dir/windows/data.img")" \
      "$(shape_of "$dir" CORES)" "$(shape_of "$dir" RAM)" "$dir"
  done < <(backups)
}

# A backup goes only by its exact path as `list` names it, so nothing else
# (the VM's own folder, a half-made copy, a symlink, a folder that merely
# looks like one) can be passed in.
delete_backup() {
  local target=${1-} dir found= real vm=
  [[ -n $target ]] || die "usage: backup.sh delete PATH"
  choose_root
  while IFS=$'\t' read -r _ dir; do
    [[ $dir == "$target" ]] && found=1
  done < <(backups)
  [[ -n $found ]] || die "not a backup: $target"
  real=$(/usr/bin/realpath -e -- "$target" 2>/dev/null) || die "cannot read $target"
  if [[ -e $windows ]]; then
    vm=$(/usr/bin/realpath -e -- "$windows" 2>/dev/null) || die "cannot read $windows"
    [[ $real != "$vm" && $vm != "$real"/* ]] || die "refusing to delete the VM itself: $target"
  fi
  /usr/bin/rm -rf -- "$real" || die "could not delete $target"
  printf 'deleted=%s\n' "$target"
}

# Whether Windows runs: vm-state.sh's pid, which it reads from /proc as the
# user. Unknown counts as running: restore refuses rather than guess.
vm_running() {
  if [[ -n ${VM_RUNNING-} ]]; then
    [[ $VM_RUNNING == 1 ]]
    return
  fi
  local line
  line=$(/usr/bin/bash "${BASH_SOURCE[0]%/*}/vm-state.sh" 2>/dev/null) || return 0
  [[ $line == *" pid= "* ]] && return 1
  return 0
}

# One field of a credentials file, split on the first = (as credentials.sh).
credential_of() {
  local file=$1 want=$2 key value
  [[ -f $file ]] || return 1
  while IFS='=' read -r key value; do
    if [[ $key == "$want" ]]; then
      printf '%s' "$value"
      return 0
    fi
  done <"$file"
  return 1
}

# The rules credentials.sh and Omarchy's helper hold a login to.
login_ok() {
  local username=$1 password=$2 back
  [[ $username =~ ^[A-Za-z0-9_-]{1,20}$ ]] || return 1
  local LC_ALL=C.UTF-8
  [[ $password =~ ^[[:print:]]{1,64}$ ]] || return 1
  IFS='=' read -r _ back <<<"PASSWORD=$password"
  [[ $back == "$password" ]]
}

# A whole number of GiB, the image's apparent size: what DISK_SIZE says.
image_disk() {
  local bytes
  bytes=$(/usr/bin/stat -Lc '%s' -- "$1" 2>/dev/null) || return 1
  [[ $bytes =~ ^[0-9]{1,19}$ ]] && ((10#$bytes >= 1073741824 && 10#$bytes % 1073741824 == 0)) || return 1
  printf '%sG' "$((10#$bytes / 1073741824))"
}

timezone() {
  local value=${TZ_NAME-$(/usr/bin/timedatectl show -p Timezone --value 2>/dev/null)}
  [[ $value =~ ^[A-Za-z0-9_/.+-]{1,64}$ ]] || value=UTC
  printf '%s' "$value"
}

# As credentials.sh writes it: mktemp beside it under umask 077, 0600, mv.
save_login() {
  local username=$1 password=$2 dir tmp old_umask
  dir=${credentials%/*}
  /usr/bin/mkdir -p -- "$dir" && /usr/bin/chmod 0700 -- "$dir" || return 1
  old_umask=$(umask)
  umask 077
  tmp=$(/usr/bin/mktemp "$dir/.credentials.XXXXXX") || { umask "$old_umask"; return 1; }
  if ! printf 'USERNAME=%s\nPASSWORD=%s\n' "$username" "$password" >"$tmp" ||
    ! /usr/bin/chmod 0600 -- "$tmp" || ! /usr/bin/mv -fT -- "$tmp" "$credentials"; then
    /usr/bin/rm -f -- "$tmp"
    umask "$old_umask"
    return 1
  fi
  umask "$old_umask"
}

staging=
aside=

# Every entry of one folder into another, dotfiles included, by rename.
move_entries() {
  local from=$1 to=$2
  [[ -z $(/usr/bin/find "$from" -mindepth 1 -maxdepth 1 -print -quit) ]] && return 0
  /usr/bin/find "$from" -mindepth 1 -maxdepth 1 -exec /usr/bin/mv -t "$to" -- {} +
}

# After the swap: the backup's files back out to staging, the VM's own back in.
swap_back() {
  move_entries "$real" "$staging" && move_entries "$aside" "$real" &&
    /usr/bin/rmdir -- "$aside" && aside=
}

# Cancel, or a failure: the hidden copy goes, the VM stays.
abandon_restore() {
  [[ -n $copy_pid ]] && kill "$copy_pid" 2>/dev/null && wait "$copy_pid" 2>/dev/null
  [[ -n $staging && -d $staging ]] && /usr/bin/rm -rf -- "$staging"
  [[ -n $staging ]] && /usr/bin/rm -f -- "$staging.errors"
  return 0
}

# The backup's windows/ copied into a hidden folder in $2 named for $3, +C
# when its data.img is, so on btrfs it shares the backup's blocks: `copied=`
# lines while it runs. A failure removes the copy and exits.
stage_backup() {
  local src=$1 parent=$2 name=$3
  echo "step=copy"
  local old_umask errors status=0
  staging=$parent/.$name.restoring
  [[ ! -e $staging ]] || /usr/bin/rm -rf -- "$staging"
  old_umask=$(umask)
  umask 077
  /usr/bin/mkdir -- "$staging" || die "cannot make $staging"
  umask "$old_umask"
  local flags
  flags=$(/usr/bin/lsattr -d -- "$src/data.img" 2>/dev/null) && [[ ${flags%% *} == *C* ]] && set_nocow "$staging"
  errors=$staging.errors
  /usr/bin/cp -a --reflink=auto --sparse=always -- "$src/." "$staging/" 2>"$errors" &
  copy_pid=$!
  while kill -0 "$copy_pid" 2>/dev/null; do
    printf 'copied=%s\n' "$(occupied "$staging" || echo 0)"
    /usr/bin/sleep 1 &
    wait $! 2>/dev/null
  done
  wait "$copy_pid" || status=$?
  copy_pid=
  if ((status != 0)); then
    local why
    why=$(/usr/bin/tail -n 1 -- "$errors" 2>/dev/null)
    /usr/bin/rm -f -- "$errors"
    abandon_restore
    die "copying the backup failed: ${why:-cp exited with status $status}"
  fi
  /usr/bin/rm -f -- "$errors"
}

# A VM is installed while Omarchy's compose is there, the old one in
# ~/.config/windows included, as vm-state.sh counts it.
installed() {
  [[ -e $compose_file || -e $legacy_compose ]]
}

# The folder a backup was made beside, by its name: windows.bak-2026-10-20-2
# came from windows, .windows.bak-2026-10-04 from .windows.
origin_of() {
  local name=${1##*/}
  [[ $name =~ ^(.+)\.bak-[0-9]{4}-[0-9]{2}-[0-9]{2}(-[0-9]{1,2})?$ ]] || return 1
  printf '%s/%s' "${1%/*}" "${BASH_REMATCH[1]}"
}

empty_dir() {
  [[ -d $1 && ! -L $1 && -z $(/usr/bin/find "$1" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null) ]]
}

# The launcher's Windows entry, as Omarchy's install writes it.
write_launcher() {
  [[ -e $apps/windows-vm.desktop ]] && return 0
  /usr/bin/mkdir -p -- "$apps" || return 1
  printf '%s\n' '[Desktop Entry]' 'Name=Windows' \
    'Comment=Start Windows VM via Docker and connect with RDP' \
    'Exec=uwsm app -- omarchy-windows-vm launch' 'Icon=windows' 'Terminal=false' \
    'Type=Application' 'Categories=System;Virtualization;' >"$apps/windows-vm.desktop"
}

# Undoing a restore after Remove VM that did not finish: the copy put in
# place goes (the folder was empty or missing before), and so does the link.
dest=
made_dest=0
made_link=0
emptied=0
undo_fresh() {
  if ((made_link)); then
    /usr/bin/rm -f -- "$windows"
    made_link=0
  fi
  if ((emptied)); then
    ( umask 077 && /usr/bin/mkdir -- "$windows" )
    emptied=0
  fi
  if [[ -n $dest && -d $dest ]]; then
    if ((made_dest)); then
      /usr/bin/rm -rf -- "$dest"
    else
      /usr/bin/find "$dest" -mindepth 1 -maxdepth 1 -exec /usr/bin/rm -rf -- {} +
    fi
  fi
  dest=
  abandon_restore
}

restore_fresh() {
  local chosen=$1 cores=$2 ram=$3 src=$1/windows origin parent name link=0
  # shellcheck disable=SC2015 # both halves are tests; die exits
  [[ $cores =~ ^[0-9]{1,2}$ ]] && ((10#$cores >= 1)) || die "usage: restoring with no VM needs --cores N"
  [[ $ram =~ ^[0-9]{1,3}G$ ]] || die "usage: restoring with no VM needs --ram NG"
  origin=$(origin_of "$chosen") || die "not a backup's name: $chosen"

  local bu bp bdisk
  bdisk=$(image_disk "$src/data.img") || die "the backup's disk is not a whole number of GB"
  [[ -f $chosen/credentials ]] || die "this backup has no login, so it can't bring the VM back by itself: Install… makes a new one"
  bu=$(credential_of "$chosen/credentials" USERNAME) || die "the backup's credentials have no USERNAME"
  bp=$(credential_of "$chosen/credentials" PASSWORD) || die "the backup's credentials have no PASSWORD"
  login_ok "$bu" "$bp" || die "the backup's login is not one Omarchy can use"

  # Where it goes: the folder it was made beside, empty or missing. When that
  # isn't ~/.windows itself, ~/.windows has to be free to link to it again.
  if [[ $origin != "$windows" ]]; then
    if [[ -L $windows ]]; then
      [[ $(/usr/bin/realpath -m -- "$windows") == "$(/usr/bin/realpath -m -- "$origin")" ]] ||
        die "$windows links somewhere else; remove that link first"
    elif [[ -e $windows ]]; then
      empty_dir "$windows" || die "$windows already holds files; move them away first"
      link=1
    else
      link=1
    fi
  fi
  if [[ -e $origin || -L $origin ]]; then
    empty_dir "$origin" || die "$origin already holds files; move them away first"
    [[ -O $origin ]] || die "$origin is not yours"
  fi
  parent=${origin%/*}
  name=${origin##*/}
  [[ -d $parent && -w $parent ]] || die "cannot write in $parent"

  # Room: nothing when the copy can share the backup's blocks.
  local staged need free
  staged=$(occupied "$src/.") || die "cannot read the size of $src"
  need=$((staged + spare))
  [[ $(/usr/bin/stat -c %d -- "$src/." 2>/dev/null) == $(/usr/bin/stat -c %d -- "$parent/." 2>/dev/null) ]] &&
    [[ $(/usr/bin/stat -f -c %T -- "$parent/." 2>/dev/null) == btrfs || $(/usr/bin/stat -f -c %T -- "$parent/." 2>/dev/null) == xfs ]] &&
    need=$spare
  root=$parent
  free=$(free_bytes)
  [[ $free =~ ^[0-9]{1,19}$ ]] || die "cannot read the free space in $parent"
  ((free >= need)) || die "not enough room: putting the backup back needs $((need / spare)) GB free in $parent, it has $((free / spare)) GB"

  # 1. the copy, then in place
  trap 'abandon_restore; exit 130' TERM INT HUP
  stage_backup "$src" "$parent" "$name"
  trap '' TERM INT HUP
  echo "step=swap"
  dest=$origin
  if [[ -d $dest ]]; then
    move_entries "$staging" "$dest" || { undo_fresh; die "could not put the backup in $dest"; }
    /usr/bin/rmdir -- "$staging"
  else
    /usr/bin/mv -T -- "$staging" "$dest" || { undo_fresh; die "could not put the backup in $dest"; }
    made_dest=1
  fi
  staging=
  /usr/bin/chmod 0700 -- "$dest"

  # 2. the link, and the Shared folder
  if ((link)); then
    if [[ -d $windows ]]; then
      /usr/bin/rmdir -- "$windows" || { undo_fresh; die "could not replace the empty $windows with a link"; }
      emptied=1
    fi
    /usr/bin/ln -s -- "$dest" "$windows" || { undo_fresh; die "could not link $windows to $dest"; }
    made_link=1
  fi
  if [[ ! -e $shared && ! -L $shared ]]; then
    ( umask 077 && /usr/bin/mkdir -p -- "$shared" ) || { undo_fresh; die "could not make $shared"; }
  fi

  # 3. the compose, the one dialog
  echo "step=compose"
  local status=0 message=
  if [[ ${RESTORE_DRY_RUN-} == 1 ]]; then
    echo "dry run: compose not written (RAM=$ram CORES=$cores DISK=$bdisk USERNAME=$bu)"
  elif [[ ${RESTORE_DRY_RUN-} == dismiss ]]; then
    message="Error executing command as another user: Request dismissed"
    status=126
  else
    message=$(printf 'RAM=%s\nCORES=%s\nDISK=%s\nUSERNAME=%s\nPASSWORD=%s\nTZ=%s\n' \
      "$ram" "$cores" "$bdisk" "$bu" "$bp" "$(timezone)" |
      /usr/bin/pkexec /usr/bin/omarchy-windows-vm __priv write_compose 2>&1 >/dev/null) ||
      status=$?
  fi
  if ((status != 0)); then
    undo_fresh
    printf '%s\n' "${message:-write_compose exited with status $status}" | /usr/bin/head -c 2048 >&2
    exit 1
  fi
  printf 'composed=%s %s %s\n' "$cores" "$ram" "$bdisk"

  # 4. the login and the launcher entry
  save_login "$bu" "$bp" || die "the VM is back but $credentials could not be written: copy the backup's credentials file there"
  write_launcher || echo "the launcher's Windows entry could not be written; the card starts the VM all the same" >&2
  trap - TERM INT HUP
  printf 'restored=%s\n' "$chosen"
}

restore_backup() {
  local chosen= cores= ram= disk=
  chosen=${1-}
  shift || true
  while (($#)); do
    case $1 in
      --cores | --ram | --disk)
        (($# >= 2)) || die "$1 needs a value"
        case $1 in
          --cores) cores=$2 ;;
          --ram) ram=$2 ;;
          --disk) disk=$2 ;;
        esac
        shift
        ;;
      *) die "unknown option: $1" ;;
    esac
    shift
  done
  [[ -n $chosen ]] || die "usage: backup.sh restore PATH --cores N --ram NG --disk NG"
  choose_root
  local dir found=
  while IFS=$'\t' read -r _ dir; do
    [[ $dir == "$chosen" ]] && found=1
  done < <(backups)
  [[ -n $found ]] || die "not a backup: $chosen"
  # The safety backup keeps the shape the VM has.
  shape_cores=$cores
  shape_ram=$ram
  if ! installed; then
    restore_fresh "$chosen" "$cores" "$ram"
    return
  fi
  [[ -d $windows && -f $windows/data.img ]] || nothing_yet "nothing to restore over: $windows has no data.img"
  vm_running && die "stop the VM first: a disk Windows is using can't be swapped"

  local src=$chosen/windows real parent name
  real=$(/usr/bin/realpath -e -- "$windows") || die "cannot read $windows"
  parent=${real%/*}
  name=${real##*/}
  [[ -w $parent ]] || die "cannot write beside $real"

  # The login and disk the restored VM will have, and whether the compose
  # has to say so.
  local bu bp cu cp bdisk compose=0
  bdisk=$(image_disk "$src/data.img") || die "the backup's disk is not a whole number of GB"
  cu=$(credential_of "$credentials" USERNAME) || cu=
  cp=$(credential_of "$credentials" PASSWORD) || cp=
  if [[ -f $chosen/credentials ]]; then
    bu=$(credential_of "$chosen/credentials" USERNAME) || die "the backup's credentials have no USERNAME"
    bp=$(credential_of "$chosen/credentials" PASSWORD) || die "the backup's credentials have no PASSWORD"
  else
    bu=$cu
    bp=$cp
  fi
  login_ok "$bu" "$bp" || die "the backup's login is not one Omarchy can use"
  [[ $bu == "$cu" && $bp == "$cp" && $bdisk == "$disk" ]] || compose=1
  if ((compose)); then
    # shellcheck disable=SC2015 # both halves are tests; die exits
    [[ $cores =~ ^[0-9]{1,2}$ ]] && ((10#$cores >= 1)) || die "the VM's core count is not known yet: start it once first"
    [[ $ram =~ ^[0-9]{1,3}G$ ]] || die "the VM's RAM size is not known yet: start it once first"
  fi

  # Room for both copies, before anything is made: the safety backup as
  # `plan` reckons it, then the staged copy, free when it can share the
  # backup's blocks, its whole written size when it can't.
  plan
  ((ok)) || die "not enough room for the safety backup: it needs $(((reflink ? spare : used + spare) / spare)) GB free, $root has $((free / spare)) GB"
  local staged need left
  staged=$(occupied "$src/.") || die "cannot read the size of $src"
  need=$((staged + spare))
  [[ $(/usr/bin/stat -c %d -- "$src/." 2>/dev/null) == $(/usr/bin/stat -c %d -- "$parent/." 2>/dev/null) ]] &&
    [[ $(/usr/bin/stat -f -c %T -- "$parent/." 2>/dev/null) == btrfs || $(/usr/bin/stat -f -c %T -- "$parent/." 2>/dev/null) == xfs ]] &&
    need=$spare
  left=$free
  ((reflink)) || left=$((free - used))
  ((left >= need)) || die "not enough room: putting the backup back needs $((need / spare)) GB free beside $real after the safety backup"

  # 1. the safety backup, exactly as `run` makes one
  echo "step=safety"
  run
  trap 'abandon_restore; exit 130' TERM INT HUP

  # 2. the backup, staged beside the VM
  stage_backup "$src" "$parent" "$name"
  # From here nothing is half-done for long: no cancel.
  trap '' TERM INT HUP

  # 3. the swap. Omarchy pins ~/.windows by device and inode: it binds that
  # folder into its own mount tree and checks the pin on every start, so the
  # folder itself must stay. Its entries move out to a hidden folder beside
  # it and the staged ones move in: renames on one filesystem.
  echo "step=swap"
  aside=$parent/.$name.replaced
  [[ ! -e $aside ]] || /usr/bin/rm -rf -- "$aside"
  ( umask 077 && /usr/bin/mkdir -- "$aside" ) || { abandon_restore; die "cannot make $aside"; }
  if ! move_entries "$real" "$aside"; then
    move_entries "$aside" "$real"
    /usr/bin/rmdir -- "$aside"
    aside=
    abandon_restore
    die "could not move the VM's files aside; the VM is as it was"
  fi
  if ! move_entries "$staging" "$real"; then
    swap_back || die "could not put the backup in place, nor the VM's own files back: they are in $aside; move them into $real"
    abandon_restore
    die "could not put the backup in place; the VM is as it was"
  fi

  # 4. the compose, when the login or the disk differs: last, so a dismissed
  # dialog or a failure puts the VM's own files back and nothing has changed
  if ((compose)); then
    echo "step=compose"
    status=0
    local message=
    if [[ ${RESTORE_DRY_RUN-} == 1 ]]; then
      echo "dry run: compose not rewritten (RAM=$ram CORES=$cores DISK=$bdisk USERNAME=$bu)"
    elif [[ ${RESTORE_DRY_RUN-} == dismiss ]]; then
      message="Error executing command as another user: Request dismissed"
      status=126
    else
      message=$(printf 'RAM=%s\nCORES=%s\nDISK=%s\nUSERNAME=%s\nPASSWORD=%s\nTZ=%s\n' \
        "$ram" "$cores" "$bdisk" "$bu" "$bp" "$(timezone)" |
        /usr/bin/pkexec /usr/bin/omarchy-windows-vm __priv write_compose 2>&1 >/dev/null) ||
        status=$?
    fi
    if ((status != 0)); then
      swap_back || die "the compose was not rewritten, and the VM's own files could not be put back: they are in $aside; move them into $real"
      abandon_restore
      printf '%s\n' "${message:-write_compose exited with status $status}" | /usr/bin/head -c 2048 >&2
      exit 1
    fi
    # The shape the next start will use, for the card's "next start" line.
    printf 'composed=%s %s %s\n' "$cores" "$ram" "$bdisk"
  fi

  # 5. done: the VM's old files go (step 1 holds them), and the login
  /usr/bin/rm -rf -- "$aside"
  aside=
  /usr/bin/rmdir -- "$staging" 2>/dev/null
  staging=
  if [[ $bu != "$cu" || $bp != "$cp" ]]; then
    save_login "$bu" "$bp" || die "the disk is restored but $credentials could not be rewritten: copy the backup's credentials file over it"
  fi
  trap - TERM INT HUP
  printf 'restored=%s\n' "$chosen"
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
  if [[ $shape_cores =~ ^[0-9]{1,2}$ && $shape_ram =~ ^[0-9]{1,3}G$ ]]; then
    printf 'CORES=%s\nRAM=%s\n' "$shape_cores" "$shape_ram" >"$partial/shape" || {
      abandon
      die "could not write $partial/shape"
    }
  fi

  /usr/bin/mv -T -- "$partial" "$root/$target" || {
    abandon
    die "could not rename $partial"
  }
  partial=
  trap - TERM INT HUP
  remember_place "$root"
  printf 'done=%s\n' "$root/$target"
}

# `run`'s and `restore`'s --cores and --ram, what a backup keeps as its shape.
shape_args() {
  while (($#)); do
    case $1 in
      --cores | --ram)
        (($# >= 2)) || die "$1 needs a value"
        [[ $1 == --cores ]] && shape_cores=$2 || shape_ram=$2
        shift
        ;;
      *) die "unknown option: $1" ;;
    esac
    shift
  done
}

case ${1-} in
  plan) print_plan ;;
  run)
    shift
    shape_args "$@"
    run
    ;;
  list) print_list ;;
  delete) delete_backup "${2-}" ;;
  restore)
    shift
    restore_backup "$@"
    ;;
  *) die "usage: backup.sh plan | run | list | delete PATH | restore PATH ..." ;;
esac
