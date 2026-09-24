#!/bin/bash
# Changes the shape of Omarchy's Windows VM for chaves.omawin: cores, RAM and
# the guest disk, with the login left exactly as it is.
#
#   helpers/tune.sh limits
#       One line of key=value with everything the Tune face needs to draw its
#       controls, and nothing the VM has to be running for:
#
#         cores=8 ram=32 free=412 disk=64G login=chaves
#
#         cores  nproc: the most this machine can give the guest
#         ram    MemTotal in whole GiB, which caps the RAM chips
#         free   df of ~/.windows in whole GiB, the same reading
#                omarchy-windows-vm's own available_storage_gb takes
#         disk   apparent size of ~/.windows/data.img, the current DISK_SIZE
#         login  the USERNAME line of the credentials file (never the password)
#
#   helpers/tune.sh apply --cores N --ram NG --disk NG
#       Writes that shape into Omarchy's root-owned compose and prints `ok`.
#       Refuses, with one line on stderr and status 2, anything the root-side
#       writer would refuse or the machine cannot hold; status 1 is a write
#       that was attempted and failed (pkexec's or the helper's own words).
#
# Omarchy's `install` is a gum wizard around ONE privileged action,
# `__priv write_compose`, which takes six KEY=VALUE lines on stdin and rewrites
# the compose as root. That is what this calls — nothing is re-downloaded, the
# existing data.img is kept, and the login is read out of the credentials file
# and passed straight back in, so the Windows account is never touched.
#
# The root side re-validates every field (it is the security boundary: the
# image, the container name, the ports, the devices and both bind anchors are
# hard-coded there and never taken from this input). The same regexes are
# applied here, before pkexec, so a typo is a sentence on the card instead of
# an authentication dialog followed by a refusal:
#
#   RAM ^[0-9]{1,3}G$   CORES ^[0-9]{1,2}$ and >= 1   DISK ^[0-9]{1,4}G$
#   USERNAME ^[A-Za-z0-9_-]{1,20}$   PASSWORD ^[[:print:]]{1,64}$
#
# Plus three guards of its own, none of which the root side knows about:
# cores <= nproc, RAM <= MemTotal, and the two disk rules — dockur never
# shrinks data.img, and the wizard wants DISK + 10 GB free (counted without
# subtracting the image that is already there, exactly as `install` counts it).
#
# The new shape only takes effect at the next `docker compose up`, so the
# widget only offers this while the VM is stopped.
#
# The password is read here and piped into pkexec; it is never an argument
# (every /proc/<pid>/cmdline on the machine is world-readable), never printed
# and never logged, not even on the dry run. write_compose is deliberately NOT
# one of the command lines polkit/49-omawin.rules.in allows: rewriting the VM's
# configuration asks for authorisation every time, on purpose.
#
# Environment (all optional, the defaults are the real system; the tests use
# them to run every guard without a VM):
#   CREDENTIALS_FILE  the VM credentials     (default ~/.config/windows/credentials)
#   DATA_IMAGE        the guest disk image   (default ~/.windows/data.img)
#   LEGACY_COMPOSE_FILE  the pre-move compose, only for which advice to give
#                     (default ~/.config/windows/docker-compose.yml)
#   WINDOWS_DIR       what `free` measures   (default ~/.windows, else ~)
#   HOST_CORES        skip nproc, use this value
#   HOST_RAM_GB       skip /proc/meminfo, use this value
#   FREE_GB           skip df, use this value
#   TZ_NAME           skip timedatectl, use this value
#   TUNE_DRY_RUN      =1 prints the six lines it would pipe to pkexec instead
#                     of running it, with PASSWORD=*** in place of the secret

set -uo pipefail
export LC_ALL=C

credentials=${CREDENTIALS_FILE:-$HOME/.config/windows/credentials}
data_image=${DATA_IMAGE:-$HOME/.windows/data.img}
windows_dir=${WINDOWS_DIR:-$HOME/.windows}

# The headroom `install` leaves for the Windows image on top of the disk.
RESERVE_GB=10

die() {
  echo "$*" >&2
  exit 2
}

# --- the readings -----------------------------------------------------------

host_cores() {
  local value=${HOST_CORES-$(/usr/bin/nproc 2>/dev/null)}
  [[ $value =~ ^[0-9]{1,4}$ ]] && ((10#$value >= 1)) || value=
  printf '%s' "$value"
}

host_ram_gb() {
  local value= key kb
  # Set but empty means "unknown", the same as DOCKER_STATE= in the sampler:
  # the guard is then skipped rather than measured against the real machine.
  if [[ -n ${HOST_RAM_GB+set} ]]; then
    value=$HOST_RAM_GB
  else
    while read -r key kb _; do
      [[ $key == MemTotal: ]] || continue
      [[ $kb =~ ^[0-9]{1,12}$ ]] && value=$((10#$kb / 1048576))
      break
    done 2>/dev/null </proc/meminfo
  fi
  [[ $value =~ ^[0-9]{1,6}$ ]] && ((10#$value >= 1)) || value=
  printf '%s' "$value"
}

# Whole GiB free where the image lives, or where it would be created. The same
# df -P reading omarchy-windows-vm takes, for the same reason: the wizard's
# "DISK + 10 GB" rule has to be applied to the same number it would see.
free_gb() {
  local value= path=$windows_dir
  if [[ -n ${FREE_GB+set} ]]; then
    value=$FREE_GB
  else
    [[ -d $path ]] || path=$HOME
    value=$(/usr/bin/df -P -- "$path" 2>/dev/null | /usr/bin/awk 'NR==2 {print int($4/1024/1024)}')
  fi
  [[ $value =~ ^[0-9]{1,9}$ ]] || value=
  printf '%s' "$value"
}

# The configured DISK_SIZE, read off the only file that records it and is ours:
# the apparent size of the sparse data.img. Empty when it is not there yet.
current_disk() {
  local bytes
  bytes=$(/usr/bin/stat -Lc '%s' -- "$data_image" 2>/dev/null) || return 0
  [[ $bytes =~ ^[0-9]{1,19}$ ]] && ((10#$bytes >= 1073741824)) &&
    ((10#$bytes % 1073741824 == 0)) || return 0
  printf '%sG' "$((10#$bytes / 1073741824))"
}

# One field of the credentials file. IFS on the first = only, so a password
# that contains = survives — the same read omarchy-windows-vm's own
# read_credential does.
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

timezone() {
  local value=${TZ_NAME-$(/usr/bin/timedatectl show -p Timezone --value 2>/dev/null)}
  [[ $value =~ ^[A-Za-z0-9_/.+-]{1,64}$ ]] || value=UTC
  printf '%s' "$value"
}

# --- limits -----------------------------------------------------------------

limits() {
  local login
  login=$(credential USERNAME) || login=
  [[ $login =~ ^[A-Za-z0-9_-]{1,20}$ ]] || login=
  printf 'cores=%s ram=%s free=%s disk=%s login=%s\n' \
    "$(host_cores)" "$(host_ram_gb)" "$(free_gb)" "$(current_disk)" "$login"
}

# --- apply ------------------------------------------------------------------

apply() {
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

  # The root writer's own shapes, applied before anything is elevated.
  # shellcheck disable=SC2015 # both halves are tests; die exits
  [[ $cores =~ ^[0-9]{1,2}$ ]] && ((10#$cores >= 1)) || die "not a number of cores: $cores"
  [[ $ram =~ ^[0-9]{1,3}G$ ]] || die "not a RAM size: $ram"
  [[ $disk =~ ^[0-9]{1,4}G$ ]] || die "not a disk size: $disk"

  local max_cores max_ram
  max_cores=$(host_cores)
  max_ram=$(host_ram_gb)
  [[ -z $max_cores ]] || ((10#$cores <= 10#$max_cores)) ||
    die "$cores cores is more than the $max_cores this machine has"
  [[ -z $max_ram ]] || ((10#${ram%G} <= 10#$max_ram)) ||
    die "$ram is more RAM than this machine has (${max_ram}G)"

  # Grow only: dockur refuses to shrink data.img, and a DISK_SIZE below what
  # the image already is would fail at the next start instead of here.
  local now
  now=$(current_disk)
  [[ -z $now ]] || ((10#${disk%G} >= 10#${now%G})) ||
    die "the disk cannot shrink: data.img is already $now"

  # The wizard's rule, counted the way the wizard counts it: the image that is
  # already there is not subtracted.
  local free need=$((10#${disk%G} + RESERVE_GB))
  free=$(free_gb)
  [[ -z $free ]] || ((10#$free >= need)) ||
    die "not enough room: $disk needs $need GB free (disk + $RESERVE_GB GB), $free GB left"

  local username password tz
  # An install from before Omarchy moved the compose has no credentials file
  # until its first launch writes one; reinstalling would be the wrong advice.
  [[ -f $credentials || ! -f ${LEGACY_COMPOSE_FILE:-$HOME/.config/windows/docker-compose.yml} ]] ||
    die "start the VM once first: Omarchy finishes moving its settings then"
  username=$(credential USERNAME) ||
    die "no credentials at $credentials: run omarchy-windows-vm install first"
  password=$(credential PASSWORD) ||
    die "no password stored in $credentials"
  [[ $username =~ ^[A-Za-z0-9_-]{1,20}$ ]] ||
    die "the stored username is not one the VM writer accepts"
  [[ $password =~ ^[[:print:]]{1,64}$ ]] ||
    die "the stored password is not a single printable line: set it again with Update password"

  tz=$(timezone)

  if [[ ${TUNE_DRY_RUN-} == 1 ]]; then
    printf 'RAM=%s\nCORES=%s\nDISK=%s\nUSERNAME=%s\nPASSWORD=***\nTZ=%s\n' \
      "$ram" "$cores" "$disk" "$username" "$tz"
    echo ok
    exit 0
  fi

  # One authorisation, one action. stdin is the only channel the secret takes.
  # The writer's own stderr is passed through as it is — pkexec's "Request
  # dismissed" is how the widget tells a cancelled dialog from a real failure,
  # and the root side's "invalid …" lines are what the card should quote.
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
  echo ok
}

case ${1-} in
  limits)
    shift
    (($# == 0)) || die "limits takes no arguments"
    limits
    ;;
  apply)
    shift
    apply "$@"
    ;;
  *) die "usage: tune.sh limits | tune.sh apply --cores N --ram NG --disk NG" ;;
esac
