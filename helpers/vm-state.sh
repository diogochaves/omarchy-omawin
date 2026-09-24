#!/bin/bash
# Unprivileged state sampler for chaves.omawin (Omarchy's Docker Windows VM).
#
# Prints ONE line of key=value pairs; every key is always present, so the
# caller can parse it without caring which state the VM is in:
#
#   installed=1 docker=active pid=1360395 frozen=0 cores=4 ram=16G web=401 cid=3fff20be… started=1757555121 disk=64G login=chaves
#   installed=1 docker=active pid= frozen= cores= ram= web=000 cid= started= disk=64G login=chaves
#   installed=0 docker=active pid= frozen= cores= ram= web=000 cid= started= disk= login=
#
#   installed  both the compose and the credentials file exist, or, on an
#              install from before Omarchy moved the compose, the old one in
#              ~/.config/windows does (1/0). omarchy-windows-vm treats that
#              one as configured too: `launch`, `stop` and `remove` each move
#              it (migrate_legacy_compose), writing the credentials file on
#              the way, so the first Start from the card finishes the move.
#   docker     systemctl is-active docker.service
#   pid        the VM's QEMU pid: comm is "windows" (the compose passes
#              -name Windows,process=windows) AND the cgroup is a docker-
#              scope AND argv[0] is qemu-system-x86_64. Empty when stopped.
#   frozen     cgroup.freeze of that scope: 1 after `docker pause`
#   cores/ram  the -smp and -m arguments of the live QEMU command line
#   web        HTTP status of the dockur web viewer on 8006 (401 = up, it is
#              behind basic auth; 000 = closed)
#   cid        the 64-hex container id from the docker-<id>.scope cgroup
#   started    when that QEMU process started, in epoch seconds: field 22 of
#              /proc/<pid>/stat (ticks since boot) over USER_HZ, which is 100
#              on Linux whatever the kernel HZ, plus /proc/stat's btime. No
#              getconf, no ps, no fork. Empty when there is no pid.
#   disk       the VM's disk as the guest sees it: the APPARENT size of
#              ~/.windows/data.img (stat -c %s, the user's own file — the image
#              is sparse, so this is the configured DISK_SIZE and not the space
#              it occupies), in whole GiB with a G, e.g. 64G. Empty when the
#              file is missing or not a whole number of GiB. This is the only
#              readable record of DISK_SIZE: the compose is root:docker 0640.
#   login      the USERNAME line of the credentials file, nothing else. The
#              password is never printed, never read here: the Login face asks
#              helpers/credentials.sh for it, on demand. On a not yet moved
#              install, the USERNAME of the old compose instead.
#
# When installed=0 there is no Omarchy VM to look at, so neither the /proc
# scan nor the web probe runs and every other key comes back empty.
#
# No docker CLI, no socket, no privileges: everything here is a /proc or /sys
# read that is world-readable even though QEMU runs as root. The only forks
# are `systemctl is-active` and, when installed, one short `curl`.
#
# Environment (all optional, the defaults are the real system):
#   PROC_ROOT         procfs root            (default /proc)
#   SYS_ROOT          sysfs root             (default /sys)
#   COMPOSE_FILE      Omarchy's compose      (default /var/lib/omarchy/windows/docker-compose.yml)
#   LEGACY_COMPOSE_FILE  the pre-move compose (default ~/.config/windows/docker-compose.yml)
#   CREDENTIALS_FILE  the VM credentials     (default ~/.config/windows/credentials)
#   DATA_IMAGE        the guest disk image   (default ~/.windows/data.img)
#   DOCKER_STATE      skip systemctl, use this value
#   WEB_CODE          skip curl, use this value (still only when installed)

set -uo pipefail
export LC_ALL=C
# No pids: the glob must vanish, not be read as a literal path. Every /proc
# read below puts its 2>/dev/null FIRST, so bash has already redirected stderr
# when the redirection itself fails on a process that exited mid-scan.
shopt -s nullglob

proc_root=${PROC_ROOT:-/proc}
sys_root=${SYS_ROOT:-/sys}
compose=${COMPOSE_FILE:-/var/lib/omarchy/windows/docker-compose.yml}
legacy_compose=${LEGACY_COMPOSE_FILE:-$HOME/.config/windows/docker-compose.yml}
credentials=${CREDENTIALS_FILE:-$HOME/.config/windows/credentials}
data_image=${DATA_IMAGE:-$HOME/.windows/data.img}

# The same test migrate_legacy_compose makes: the old file only counts while
# the new one is not there yet.
installed=0 legacy=0
if [[ -f $compose && -f $credentials ]]; then
  installed=1
elif [[ ! -f $compose && -f $legacy_compose ]]; then
  installed=1 legacy=1
fi

docker=${DOCKER_STATE-$(/usr/bin/systemctl is-active docker.service 2>/dev/null)}
[[ $docker =~ ^[a-z-]{0,32}$ ]] || docker=

pid= frozen= cores= ram= cid= started= web=000 disk= login=
if ((installed)); then
  # The guest disk, in whole GiB. stat prints the apparent size, which for this
  # sparse image is the DISK_SIZE the compose was written with — the compose
  # itself is root:docker 0640 and cannot be read here.
  if bytes=$(/usr/bin/stat -Lc '%s' -- "$data_image" 2>/dev/null) &&
    [[ $bytes =~ ^[0-9]{1,19}$ ]] && ((10#$bytes >= 1073741824)) &&
    ((10#$bytes % 1073741824 == 0)); then
    disk=$((10#$bytes / 1073741824))G
  fi
  [[ $disk =~ ^[0-9]{1,4}G$ ]] || disk=
  # Only the username, and only if it looks like one (the helper's own
  # valid_username). IFS on the first = is how omarchy-windows-vm reads this
  # file; the PASSWORD line is skipped without ever being assigned.
  if ((legacy)); then
    # The old compose is the user's own file; its environment block holds
    # `USERNAME: "name"`, read the way the helper's read_compose_value reads
    # it. The PASSWORD line next to it never matches.
    while IFS= read -r line; do
      [[ $line =~ ^[[:space:]]*USERNAME:[[:space:]]*\"(.*)\"[[:space:]]*$ ]] || continue
      login=${BASH_REMATCH[1]}
      break
    done 2>/dev/null <"$legacy_compose"
  else
    while IFS='=' read -r key value; do
      [[ $key == USERNAME ]] || continue
      login=$value
      break
    done 2>/dev/null <"$credentials"
  fi
  [[ $login =~ ^[A-Za-z0-9_-]{1,20}$ ]] || login=
  for comm_file in "$proc_root"/[0-9]*/comm; do
    read -r comm 2>/dev/null <"$comm_file" || continue
    [[ $comm == windows ]] || continue
    dir=${comm_file%/comm}

    cgpath=
    while IFS= read -r line; do [[ $line == 0::* ]] && cgpath=${line#0::}; done \
      2>/dev/null <"$dir/cgroup"
    [[ $cgpath == *docker-* ]] || continue

    argv=()
    mapfile -d '' -t argv 2>/dev/null <"$dir/cmdline"
    [[ ${argv[0]-} == qemu-system-x86_64 ]] || continue

    pid=${dir##*/}
    [[ $pid =~ ^[0-9]{1,8}$ ]] || continue
    cid=${cgpath##*docker-}
    cid=${cid%.scope}
    [[ $cid =~ ^[0-9a-f]{12,64}$ ]] || cid=
    read -r frozen 2>/dev/null <"$sys_root/fs/cgroup$cgpath/cgroup.freeze" || frozen=
    [[ $frozen == 0 || $frozen == 1 ]] || frozen=

    # starttime is field 22, but comm (field 2) is parenthesised and may hold
    # spaces and ')' of its own, so count from the LAST ')': what follows it
    # is field 3 onwards, and field 22 is the 20th of those.
    if read -r statline 2>/dev/null <"$dir/stat"; then
      IFS=' ' read -ra stat_fields <<<"${statline##*') '}"
      btime=
      while read -r key value _; do
        if [[ $key == btime ]]; then btime=$value; break; fi
      done 2>/dev/null <"$proc_root/stat"
      # Both are digits-only before they go anywhere near $((…)), which would
      # otherwise evaluate whatever a bad /proc handed back.
      [[ $btime =~ ^[0-9]{1,12}$ && ${stat_fields[19]-} =~ ^[0-9]{1,15}$ ]] &&
        started=$((10#$btime + 10#${stat_fields[19]} / 100))
    fi

    for ((i = 1; i < ${#argv[@]}; i++)); do
      case ${argv[i - 1]} in
        -smp) cores=${argv[i]%%,*} ;;
        -m) ram=${argv[i]} ;;
      esac
    done
    # Only the two shapes QEMU is given by Omarchy's compose are printed;
    # anything else on that command line stays where it was.
    [[ $cores =~ ^[0-9]{1,4}$ ]] || cores=
    [[ $ram =~ ^[0-9]{1,6}[KMGTkmgt]?$ ]] || ram=
    break
  done
  # -q first so ~/.curlrc cannot add to the request; the body is discarded and
  # capped anyway, only the status code is wanted.
  web=${WEB_CODE-$(/usr/bin/curl -q -s -o /dev/null -w '%{http_code}' --max-time 1 --max-filesize 65536 -- http://127.0.0.1:8006/)}
  [[ $web =~ ^[0-9]{3}$ ]] || web=000
fi

printf 'installed=%s docker=%s pid=%s frozen=%s cores=%s ram=%s web=%s cid=%s started=%s disk=%s login=%s\n' \
  "$installed" "$docker" "$pid" "$frozen" "$cores" "$ram" "$web" "$cid" "$started" \
  "$disk" "$login"
