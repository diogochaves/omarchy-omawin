#!/bin/bash
# Regenerates tests/fixtures/{running,paused,stopped,not-installed}: a fake
# /proc + /sys + compose + credentials per state, so helpers/vm-state.sh can be
# run for real without a VM. The generated files are committed; this script is
# here to document where they came from.
#
# The running/paused command lines are trimmed copies of the real one on this
# box (dockur/windows 6.05, Omarchy 4.0.3-1), NUL separated like /proc. Each
# fake pid also gets a /proc/<pid>/stat, and every fixture a top-level
# /proc/stat with a btime line, so the sampler can work out `started`:
# BTIME + field 22 / 100 (USER_HZ), i.e. 1789179802 + 632100/100 = 1789186123
# for the VM.
#
# Every fixture carries three decoys the matcher must reject:
#   1001  comm "windows", qemu argv, but a user-slice cgroup (not a container)
#   1002  comm "windows", a docker cgroup, but argv[0] is not qemu
#   1003  a real qemu-system-x86_64 in a user slice (another VM on the box)
# They sort before the real pid, so a matcher that took the first "windows"
# it saw, or skipped either guard, would pick one of them.
set -euo pipefail
here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)

BTIME=1789179802          # boot time of this fake machine, epoch seconds
STARTTIME=632100          # the VM's field 22, ticks since boot: 6321 s in
CID=3fff20be218cd2379160eb8acf4144ac6aafd0dacbf17f78f2e4f020466084b9
DECOY_CID=000011112222333344445555666677778888999900001111222233334444aaaa

proc() { # fixture pid comm cgroup [starttime]
  mkdir -p "$here/$1/proc/$2"
  printf '%s\n' "$3" >"$here/$1/proc/$2/comm"
  printf '0::%s\n' "$4" >"$here/$1/proc/$2/cgroup"
  # /proc/<pid>/stat, real shape: pid (comm) state ppid … and field 22
  # (starttime) where the kernel puts it, so the sampler's "count from the
  # last ')'" parse is exercised on a line of the right length.
  printf '%s (%s) S 1 %s %s 0 -1 4194560 %s\n' "$2" "$3" "$2" "$2" \
    "$(stat_tail "${5:-$STARTTIME}")" >"$here/$1/proc/$2/stat"
}

# Fields 10 to 44 of /proc/<pid>/stat with field 22 set; the rest are zeros,
# since nothing but 22 is ever read. Fields 1 to 9 are in the printf above.
stat_tail() { # starttime
  local out= i
  for ((i = 10; i <= 44; i++)); do
    case $i in
      22) out+="$1 " ;;
      *) out+="0 " ;;
    esac
  done
  printf '%s' "${out% }"
}

args() { # fixture pid arg...
  local fixture=$1 pid=$2 arg
  shift 2
  : >"$here/$fixture/proc/$pid/cmdline"
  for arg in "$@"; do printf '%s\0' "$arg" >>"$here/$fixture/proc/$pid/cmdline"; done
}

qemu() { # fixture pid  -- the real VM's argv, shortened
  args "$1" "$2" qemu-system-x86_64 -nodefaults \
    -machine type=q35,smm=off,graphics=off,vmport=off,accel=kvm -enable-kvm \
    -cpu host,kvm=on,l3-cache=on,+hypervisor \
    -smp 4,sockets=1,dies=1,cores=4,threads=1 \
    -m 16G -name Windows,process=windows \
    -pidfile /run/shm/qemu.pid -display vnc=:0,websocket=unix:/run/shm/vnc-ws.sock \
    -monitor unix:/run/shm/monitor.sock,server=on,wait=off,nodelay=on \
    -rtc base=localtime,clock=host,driftfix=slew
}

base() { # fixture  -- an empty install plus the three decoys
  local f=$1
  rm -rf "${here:?}/$f"
  mkdir -p "$here/$f/proc"
  printf 'cpu  0 0 0 0 0 0 0 0 0 0\nbtime %s\nprocesses 12345\n' "$BTIME" \
    >"$here/$f/proc/stat"
  printf 'name: windows\n' >"$here/$f/docker-compose.yml"
  printf 'USERNAME=chaves\nPASSWORD=secret\n' >"$here/$f/credentials"

  proc "$f" 1001 windows /user.slice/user-1000.slice/session-2.scope 100
  qemu "$f" 1001
  proc "$f" 1002 windows "/system.slice/docker-$DECOY_CID.scope" 200
  args "$f" 1002 /usr/bin/windows-vm-setgid-fix --watch
  proc "$f" 1003 qemu-system-x86_64 /user.slice/user-1000.slice/session-2.scope 300
  qemu "$f" 1003
}

vm() { # fixture frozen  -- adds the real VM on top of base()
  local f=$1
  base "$f"
  proc "$f" 1360395 windows "/system.slice/docker-$CID.scope"
  qemu "$f" 1360395
  mkdir -p "$here/$f/sys/fs/cgroup/system.slice/docker-$CID.scope"
  printf '%s\n' "$2" >"$here/$f/sys/fs/cgroup/system.slice/docker-$CID.scope/cgroup.freeze"
}

vm running 0
vm paused 1

# Installed, nothing running: only the decoys are left, and none of them may
# be mistaken for the VM.
base stopped

# The VM is running, but the credentials file is gone. Omarchy calls that not
# installed and so do we: the sampler must not even look at /proc.
vm not-installed 0
rm -f "$here/not-installed/credentials"
