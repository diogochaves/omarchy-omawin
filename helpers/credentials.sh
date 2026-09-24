#!/bin/bash
# Reads and rewrites the Windows VM's RDP login for chaves.omawin.
#
#   helpers/credentials.sh username      prints the USERNAME line, nothing else
#   helpers/credentials.sh password      prints the PASSWORD line, for Reveal
#   helpers/credentials.sh copy          puts the password on the clipboard
#   helpers/credentials.sh clear         clears the clipboard again
#   helpers/credentials.sh write --cores N --ram NG [--disk NG]
#                                        the new password on STDIN: rewrites
#                                        the compose, then this file
#
# The file is ~/.config/windows/credentials: the user's own, 0600, exactly two
# lines, written by `omarchy-windows-vm install` and read by its `launch` for
# xfreerdp and by the web viewer's basic auth. So what this prints is exactly
# what logs in, and what it writes is what will be sent next time.
#
# Two lines, split on the FIRST `=` only, because a password may contain one
# (the helper's own read_credential does the same). Only the line asked for is
# ever assigned: `username` cannot print a password by accident.
#
# `write` changes what this machine SENDS; it cannot change the Windows account,
# which was created at first install. The order is deliberate:
#
#   1. validate the new password with the helper's own rule, ^[[:print:]]{1,64}$
#   2. rewrite Omarchy's root-owned compose through
#      `pkexec omarchy-windows-vm __priv write_compose` — the same one
#      authorisation Tune asks for, with the shape passed in unchanged, so the
#      fallback copy of the password inside the compose agrees with this file.
#      The shape is the one the next start will use: a Tune not yet started
#      has already written its cores, RAM and disk into the compose, and the
#      widget passes those back, the disk included — reading the disk off
#      data.img instead would quietly undo a pending grow
#   3. only then rewrite this file, atomically: mktemp in the same directory
#      under umask 077, chmod 0600, mv -fT, which is how write_credentials in
#      omarchy-windows-vm does it
#
# pkexec first because that step is the cancellable one: a dismissed dialog
# must leave both the compose and this file exactly as they were. Rewriting the
# compose means the VM has to be stopped (it is consumed at the next
# `docker compose up`), which is why the widget only offers this while it is.
#
# The password is never an argument — of this script or of anything it runs —
# because /proc/<pid>/cmdline is world-readable: it arrives on stdin, goes to
# pkexec on stdin and to wl-copy on stdin, and is never echoed back except by
# the explicit `password` read that the Reveal button asks for.
#
# Environment (all optional, the defaults are the real system):
#   CREDENTIALS_FILE  the VM credentials     (default ~/.config/windows/credentials)
#   DATA_IMAGE        the guest disk image   (default ~/.windows/data.img)
#   LEGACY_COMPOSE_FILE  the pre-move compose, only for which advice to give
#                     (default ~/.config/windows/docker-compose.yml)
#   TZ_NAME           skip timedatectl, use this value
#   CREDS_DRY_RUN     =1 skips the pkexec step (and says so, with the shape it
#                     would have written), so the tests can exercise the file
#                     rewrite without a VM or a dialog

set -uo pipefail
export LC_ALL=C

credentials=${CREDENTIALS_FILE:-$HOME/.config/windows/credentials}
data_image=${DATA_IMAGE:-$HOME/.windows/data.img}

die() {
  echo "$*" >&2
  exit 2
}

# One field, by name. IFS on the first = keeps a value that contains one.
credential() {
  local want=$1 key value
  [[ -f $credentials ]] || return 1
  while IFS='=' read -r key value; do
    if [[ $key == "$want" ]]; then
      printf '%s' "$value"
      return 0
    fi
  done <"$credentials"
  return 1
}

# `credential` is always called as `x=$(credential K) || die …`: a die() inside
# a command substitution would only kill the subshell and let the script carry
# on with an empty value.
missing="no credentials at $credentials: run omarchy-windows-vm install first"
# An install from before Omarchy moved the compose has no credentials file
# until its first launch writes one; reinstalling would be the wrong advice.
[[ -f $credentials || ! -f ${LEGACY_COMPOSE_FILE:-$HOME/.config/windows/docker-compose.yml} ]] ||
  missing="start the VM once first: Omarchy finishes moving its settings then"

current_disk() {
  local bytes
  bytes=$(/usr/bin/stat -Lc '%s' -- "$data_image" 2>/dev/null) || return 0
  [[ $bytes =~ ^[0-9]{1,19}$ ]] && ((10#$bytes >= 1073741824)) &&
    ((10#$bytes % 1073741824 == 0)) || return 0
  printf '%sG' "$((10#$bytes / 1073741824))"
}

timezone() {
  local value=${TZ_NAME-$(/usr/bin/timedatectl show -p Timezone --value 2>/dev/null)}
  [[ $value =~ ^[A-Za-z0-9_/.+-]{1,64}$ ]] || value=UTC
  printf '%s' "$value"
}

# --- the reads --------------------------------------------------------------

print_username() {
  local value
  value=$(credential USERNAME) || die "$missing"
  [[ $value =~ ^[A-Za-z0-9_-]{1,20}$ ]] || die "the stored username is not a usable one"
  printf '%s\n' "$value"
}

print_password() {
  local value
  value=$(credential PASSWORD) || die "$missing"
  [[ $value =~ ^[[:print:]]{1,64}$ ]] ||
    die "the stored password is not a single printable line"
  printf '%s\n' "$value"
}

# wl-copy forks a tiny server to own the selection and returns at once. --type
# keeps the clipboard manager from guessing, and the password goes in on stdin.
# --sensitive offers the x-kde-passwordManagerHint type beside it, which is what
# Omarchy's clipboard history (shell/plugins/clipboard/capture.sh) skips on:
# without it the password would be written to
# ~/.local/state/omarchy/clipboard-history.json and outlive the 30 s clear.
copy_password() {
  local value
  value=$(credential PASSWORD) || die "$missing"
  [[ $value =~ ^[[:print:]]{1,64}$ ]] ||
    die "the stored password is not a single printable line"
  printf '%s' "$value" | /usr/bin/wl-copy --sensitive --type text/plain ||
    die "could not reach the clipboard (wl-copy)"
}

# `wl-copy --clear` empties the clipboard whoever owns it, so it only runs while
# the clipboard still holds the password: whatever the user copied since is
# theirs and stays. The comparison happens here, with both values in this
# process only; nothing is printed.
clear_clipboard() {
  local value current
  value=$(credential PASSWORD) || return 0
  current=$(/usr/bin/timeout 2 /usr/bin/wl-paste --no-newline --type text/plain 2>/dev/null) ||
    return 0
  [[ $current == "$value" ]] || return 0
  /usr/bin/wl-copy --clear || die "could not reach the clipboard (wl-copy)"
}

# --- the write --------------------------------------------------------------

# Same atomic dance as omarchy-windows-vm's write_credentials: a temp file in
# the same directory so the rename cannot cross a filesystem, 0600 before
# anything is in it (umask 077), then mv -fT over the old one.
save_credentials() {
  local username=$1 password=$2 dir tmp old_umask
  dir=${credentials%/*}
  [[ $dir != "$credentials" ]] || dir=.
  mkdir -p -- "$dir" || return 1
  chmod 0700 -- "$dir" || return 1
  old_umask=$(umask)
  umask 077
  tmp=$(mktemp "$dir/.credentials.XXXXXX") || { umask "$old_umask"; return 1; }
  if ! printf 'USERNAME=%s\nPASSWORD=%s\n' "$username" "$password" >"$tmp" ||
    ! chmod 0600 -- "$tmp" || ! mv -fT -- "$tmp" "$credentials"; then
    rm -f -- "$tmp"
    umask "$old_umask"
    return 1
  fi
  umask "$old_umask"
}

write_password() {
  local cores= ram= disk=
  while (($#)); do
    case $1 in
      --cores)
        (($# >= 2)) || die "--cores needs a value"
        cores=$2
        shift
        ;;
      --ram)
        (($# >= 2)) || die "--ram needs a value"
        ram=$2
        shift
        ;;
      --disk)
        (($# >= 2)) || die "--disk needs a value"
        disk=$2
        shift
        ;;
      *) die "unknown option: $1" ;;
    esac
    shift
  done

  # The shape is not changed here, only carried through the writer — which
  # accepts nothing less than all six fields. Without it there is nothing to
  # write the compose with, and the widget says so instead of guessing.
  [[ $cores =~ ^[0-9]{1,2}$ ]] && ((10#$cores >= 1)) ||
    die "the VM's core count is not known yet: start it once first"
  [[ $ram =~ ^[0-9]{1,3}G$ ]] ||
    die "the VM's RAM size is not known yet: start it once first"

  # The disk is data.img's own size unless a pending Tune has grown it, in
  # which case that is what the compose already says and must keep saying.
  # Grow only, as in tune.sh: dockur never shrinks data.img.
  local now username password tz
  now=$(current_disk)
  [[ $now =~ ^[0-9]{1,4}G$ ]] ||
    die "cannot read the disk size of $data_image"
  [[ -n $disk ]] || disk=$now
  [[ $disk =~ ^[0-9]{1,4}G$ ]] || die "not a disk size: $disk"
  ((10#${disk%G} >= 10#${now%G})) ||
    die "the disk cannot shrink: data.img is already $now"
  username=$(credential USERNAME) || die "$missing"
  [[ $username =~ ^[A-Za-z0-9_-]{1,20}$ ]] || die "the stored username is not a usable one"

  # One line on stdin, no trailing newline kept, nothing echoed. read returns
  # non-zero on a last line without a newline, which is fine: it has still
  # filled `password`.
  IFS= read -r password || true
  [[ $password =~ ^[[:print:]]{1,64}$ ]] ||
    die "the password must be 1 to 64 printable characters"

  tz=$(timezone)

  if [[ ${CREDS_DRY_RUN-} == 1 ]]; then
    echo "dry run: compose not rewritten (RAM=$ram CORES=$cores DISK=$disk)"
  else
    local message status=0
    message=$(printf 'RAM=%s\nCORES=%s\nDISK=%s\nUSERNAME=%s\nPASSWORD=%s\nTZ=%s\n' \
      "$ram" "$cores" "$disk" "$username" "$password" "$tz" |
      /usr/bin/pkexec /usr/bin/omarchy-windows-vm __priv write_compose 2>&1 >/dev/null) ||
      status=$?
    if ((status != 0)); then
      printf '%s\n' "${message:-write_compose exited with status $status}" |
        /usr/bin/head -c 2048 >&2
      exit 1
    fi
  fi

  save_credentials "$username" "$password" || {
    echo "the compose was updated but $credentials could not be rewritten" >&2
    exit 1
  }
  echo ok
}

case ${1-} in
  username)
    shift
    (($# == 0)) || die "username takes no arguments"
    print_username
    ;;
  password)
    shift
    (($# == 0)) || die "password takes no arguments"
    print_password
    ;;
  copy)
    shift
    (($# == 0)) || die "copy takes no arguments"
    copy_password
    ;;
  clear)
    shift
    (($# == 0)) || die "clear takes no arguments"
    clear_clipboard
    ;;
  write)
    shift
    write_password "$@"
    ;;
  *) die "usage: credentials.sh username | password | copy | clear | write --cores N --ram NG [--disk NG]" ;;
esac
