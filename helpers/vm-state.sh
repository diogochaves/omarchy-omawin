#!/bin/bash
# Unprivileged state sampler for chaves.omawin (Omarchy's Docker Windows VM).
#
# Prints ONE line of key=value pairs; every key is always present, so the
# caller can parse it without caring which state the VM is in:
#
#   installed=1 docker=active pid=1360395 frozen=0 cores=4 ram=16G web=401 cid=3fff20be… started=1757555121
#   installed=1 docker=active pid= frozen= cores= ram= web=000 cid= started=
#   installed=0 docker=active pid= frozen= cores= ram= web=000 cid= started=
#
#   installed  both the compose and the credentials file exist (1/0)
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
#   CREDENTIALS_FILE  the VM credentials     (default ~/.config/windows/credentials)
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
credentials=${CREDENTIALS_FILE:-$HOME/.config/windows/credentials}

installed=0
[[ -f $compose && -f $credentials ]] && installed=1

docker=${DOCKER_STATE-$(systemctl is-active docker.service 2>/dev/null)}

pid= frozen= cores= ram= cid= started= web=000
if ((installed)); then
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
    cid=${cgpath##*docker-}
    cid=${cid%.scope}
    read -r frozen 2>/dev/null <"$sys_root/fs/cgroup$cgpath/cgroup.freeze" || frozen=

    # starttime is field 22, but comm (field 2) is parenthesised and may hold
    # spaces and ')' of its own, so count from the LAST ')': what follows it
    # is field 3 onwards, and field 22 is the 20th of those.
    if read -r statline 2>/dev/null <"$dir/stat"; then
      IFS=' ' read -ra stat_fields <<<"${statline##*') '}"
      btime=
      while read -r key value _; do
        if [[ $key == btime ]]; then btime=$value; break; fi
      done 2>/dev/null <"$proc_root/stat"
      [[ -n $btime && ${stat_fields[19]-} =~ ^[0-9]+$ ]] &&
        started=$((btime + stat_fields[19] / 100))
    fi

    for ((i = 1; i < ${#argv[@]}; i++)); do
      case ${argv[i - 1]} in
        -smp) cores=${argv[i]%%,*} ;;
        -m) ram=${argv[i]} ;;
      esac
    done
    break
  done
  web=${WEB_CODE-$(curl -s -o /dev/null -w '%{http_code}' --max-time 1 http://127.0.0.1:8006/)}
fi

printf 'installed=%s docker=%s pid=%s frozen=%s cores=%s ram=%s web=%s cid=%s started=%s\n' \
  "$installed" "$docker" "$pid" "$frozen" "$cores" "$ram" "$web" "$cid" "$started"
