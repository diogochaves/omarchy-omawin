# Omawin

<p align="center"><img src="preview.png" alt="Omawin: the bar glyph and the popup card of Omarchy's Windows VM in its ready, paused, booting and stopped states" width="800"></p>

`chaves.omawin` is an Omarchy bar widget for Omarchy's Docker-based Windows
VM that needs no access to the Docker socket: status comes from `/proc`, a
cgroup freeze file and a TCP probe of the guest's RDP port, actions go through
Omarchy's own `omarchy-windows-vm` helper, and the few privileged calls are
auto-approved by an optional polkit rule scoped to their exact command
lines. Nobody has to join the `docker` group.

One glyph in the bar, coloured by state, with a pulse while the VM comes up or
goes down and a badge while it is paused. Middle click starts or connects.
The popup card has one face per state — not installed, stopped, starting,
booting, ready, paused, stopping, failed — with the buttons that make sense
there: Start, Connect, Pause, Resume, Stop, Web viewer, Shared folder,
Install. The tooltip carries the state, the VM's shape and its uptime.

## Install

```sh
omarchy plugin add https://github.com/diogochaves/omarchy-omawin --enable
```

It needs Omarchy's Windows VM, which is `omarchy-windows-vm install` from a
terminal or the Install button on the card. Placement is
`omarchy bar move chaves.omawin --section right --index 0`, updates are
`omarchy plugin update chaves.omawin`.

The widget is complete as installed. Every privileged step — starting,
stopping, pausing — raises Omarchy's authentication dialog, once per press,
until you install the optional polkit rule described below.

## What it runs, reads and writes

- **Reads**, unprivileged: `/proc/<pid>/{comm,cgroup,cmdline,stat}` of the
  QEMU process to find it and its `-smp`/`-m`, `/proc/stat` for `btime`, the
  scope's `cgroup.freeze` under `/sys/fs/cgroup`, and whether
  `/var/lib/omarchy/windows/docker-compose.yml` and
  `~/.config/windows/credentials` exist. Plus `systemctl is-active
  docker.service`, `systemctl --user is-active omawin-launch` and, after a
  launch ends, the user journal of that one unit.
- **Network**: loopback only. A 19-byte X.224 Connection Request to
  `127.0.0.1:3389` and a request to `http://127.0.0.1:8006/` for its status
  code. Nothing leaves the machine.
- **Runs**: `/usr/bin/omarchy-windows-vm launch -k` inside the transient user
  unit `omawin-launch` (through `systemd-run --user`, so the RDP session
  survives a bar reload), `/usr/bin/omarchy-windows-vm stop`,
  `/usr/bin/omarchy-windows-vm install` in Omarchy's floating terminal,
  `/usr/bin/pkexec /usr/bin/docker pause|unpause omarchy-windows`,
  `systemctl --user stop omawin-launch`, and `xdg-open` on
  `http://127.0.0.1:8006` and `~/Windows`. Every command is a constant with an
  absolute path; nothing is built from data.
- **Writes**: one file, `$XDG_STATE_HOME/omawin/state.json` (see *Cache*).
  None of your configuration is touched.
- **Privilege**: none of its own. `omarchy-windows-vm` calls pkexec itself for
  `__priv up_wait` and `__priv down`; pause and unpause go through pkexec
  directly. The polkit rule is optional and installed by you, on purpose, from
  a terminal.

## Remove

```sh
omarchy plugin remove chaves.omawin
```

What can stay behind, and how to take it out:

| Artifact | After removal | To remove it |
|----------|---------------|--------------|
| `~/.local/state/omawin/state.json` (`$XDG_STATE_HOME/omawin/`) | kept | `rm -r ~/.local/state/omawin` |
| `/etc/polkit-1/rules.d/49-omawin.rules` — only if you ran `setup` | kept | `sudo ./setup polkit --remove` **before** removing the plugin, or `sudo rm /etc/polkit-1/rules.d/49-omawin.rules` after |
| the transient unit `omawin-launch.service` | exists only while an RDP window is open; gone when it closes | `systemctl --user stop omawin-launch` |

Nothing else: no packages, no hooks, no edits to Hyprland or shell config.
The VM itself is Omarchy's and is not touched by removing the widget.

## Pause and Resume

Pause is `docker pause`: a cgroup freeze, so the guest stops using CPU but
keeps its RAM, and the compose's `-rtc base=localtime,clock=host,driftfix=slew`
lets the guest clock catch up on resume. It is not a suspend to disk and it
survives neither a reboot nor a `stop`.

**Pause closes the RDP window first.** The freeze stops the guest's RDP
server too, so an open session would sit on a frozen picture until its
connection timed out, and every click made on it meanwhile would be queued
and delivered to Windows on resume. So Pause stops the `omawin-launch` unit
(the launcher exits cleanly, the VM keeps running), then freezes. Resume
unfreezes and reopens the window in one press; Connect does the same from a
paused state whose window was already closed.

**Stop on a paused VM unpauses it first.** `docker compose down` would send
SIGTERM to a frozen process, wait out the full two-minute grace period and
then SIGKILL it — an unclean Windows shutdown. So Stop runs `unpause` and only
then `omarchy-windows-vm stop`, and an unpause that fails aborts the stop
instead of leaving it to time out. Every button, Stop included, is disabled
while a pause or unpause is in flight.

## Cache

`$XDG_STATE_HOME/omawin/state.json` (`~/.local/state/omawin/state.json` by
default) holds one object written from the last running sample:

```json
{ "cores": 4, "ram": "16G", "started": 1789232550, "lastSeen": 1789236870124 }
```

That is the whole file: the VM's shape, when the last seen run of it started
(epoch seconds), and when it was last seen running (epoch milliseconds). It is
what the stopped card's `4 cores · 16G` pill, its Cores/RAM readings and its
"Last run" print — nothing else reads it and nothing else writes it. Deleting
it is safe: those four readings go blank until the VM next runs. It is
rewritten when the shape changes and at most once a minute otherwise.

## Tuning the VM

None of this is widget work, and the widget does not pretend otherwise: it
shows the VM's shape, it does not change it. What a "normal" VM offers and how
to get it here, as far as Omarchy's helper allows:

| Want | How, here | Notes |
|------|-----------|-------|
| Change cores / RAM (VM off) | `omarchy-windows-vm install` again | Re-asks everything, rewrites the compose, **starts the VM immediately** and opens the browser. Cores/RAM apply at that boot; `data.img` is kept. **Enter the same username and password**: they were baked into the guest at first install, and different ones only rewrite the credentials file and break RDP login. Needs `DISK+10 GB` free, computed without subtracting the existing image. |
| Change cores / RAM (VM on) | Not possible | No hotplug headroom in `-smp` (no `maxcpus`), no balloon device, and the QEMU monitor is `unix:/run/shm/monitor.sock` inside the container. Stop, change, start. |
| Grow the disk | `install` again with a bigger DISK | Grow only; Windows may need the partition extended in Disk Management. |
| Anything else dockur supports (KEYBOARD, REGION, LANGUAGE, DISK2_SIZE, extra ports, `/dev/bus/usb`, DHCP/macvlan networking) | `sudo` edit of `/var/lib/omarchy/windows/docker-compose.yml`, then stop/start | `assert_mounts_safe` only checks owner/mode, the two bind lines and `PROTECT`; extra keys survive. **The next `install` run overwrites them.** Keep a copy. |
| Snapshot / rollback (VM off) | `cp -a --reflink=always ~/.windows ~/.windows.snap-<date>` | On btrfs a reflink copy is instant and free until blocks diverge. Rollback = copy back while stopped. User-owned, no root. |
| Suspend to RAM | Pause | A cgroup freeze; see above. The guest clock resyncs on resume. |
| Suspend to disk | Not from outside | `savevm` needs qcow2 and the monitor. Windows' own Hibernate from inside the guest is untested. |
| Second VM | Not with the helper | Own compose, other ports, outside Omarchy. |
| Autostart at login | Not by default | Possible with the polkit rule plus a user unit that runs `omarchy-windows-vm launch -k`. |
| Logs / console | Web viewer on 8006 | `docker logs` needs the socket. |

## Polkit rule

Optional. The widget works without it — every action just raises Omarchy's
authentication dialog. `polkit/49-omawin.rules.in` is rendered with `@USER@`
filled in, shown to you in full, and only then installed as
`/etc/polkit-1/rules.d/49-omawin.rules`. It says YES to exactly five command
lines for exactly one user:

```
/usr/bin/omarchy-windows-vm __priv status | up_wait | down
/usr/bin/docker pause | unpause omarchy-windows
```

So any process running as that user can start, stop, pause and query *this
one VM*. `up_wait` only ever runs Omarchy's root-owned, validated compose file
against pinned bind anchors — that is the point of the helper's design — so it
is not a path to arbitrary root. `write_compose` and `remove` keep prompting,
`docker` stays untouchable beyond pause/unpause of the `omarchy-windows`
container, and every other user and action falls through to the normal
prompt. The directory is `root:polkitd 0750`, so installing needs root;
polkitd notices the new file by itself, nothing is restarted.

Check first that pkexec's action details are what the rule matches on. The
probe rule allows one read-only command line, `__priv status`, to the same one
user, on the same exact `program` + `command_line` test the real rule uses,
and nothing else (polkitd runs with `--log-level=notice` on Omarchy, so a
`polkit.log()` probe would show nothing). Run these from the plugin's folder,
`~/.config/omarchy/plugins/chaves.omawin`:

```sh
sudo ./setup polkit --probe
pkexec /usr/bin/omarchy-windows-vm __priv status         # must NOT prompt
pkexec /usr/bin/omarchy-windows-vm __priv status extra   # must prompt; cancel
sudo ./setup polkit                                      # the real rule; drops the probe
```

Each `setup` call prints the exact file it is about to install and waits for a
`y`; `--yes` skips the question. If you would rather not run a script as root
at all, the whole install is one line you can read first:

```sh
sed "s/@USER@/$USER/g" polkit/49-omawin.rules.in |
  sudo install -D -m 0644 -o root -g root /dev/stdin /etc/polkit-1/rules.d/49-omawin.rules
```

A prompt on the first probe call means the details differ on your box and the
rule must not be installed as written. Then verify, as the user:

```sh
pkexec /usr/bin/omarchy-windows-vm __priv status              # no dialog
pkexec /usr/bin/omarchy-windows-vm __priv write_compose </dev/null  # prompts
```

`sudo ./setup polkit --status` says which rules are installed and who they
name; `sudo ./setup polkit --remove` takes both back out. The rule is not
removed by `omarchy plugin remove`: see *Remove* above.

## Developing

Run it from a checkout instead of `plugin add`:

```sh
ln -s "$PWD" ~/.config/omarchy/plugins/chaves.omawin
omarchy-shell shell rescanPlugins
omarchy bar put chaves.omawin --before omarchy.power
```

`shell.json` hot-reloads, so the glyph appears at once; a changed `Panel.qml`
needs `omarchy restart shell`. Everything about the layout goes through
`omarchy bar` — never hand-edit `shell.json`. `node --test tests/` runs the
sampler, the probe, the state machine and `setup` unprivileged against
fixtures.

### IPC

`omarchy-shell chaves.omawin <method> [args]`, or
`qs -p /usr/share/omarchy/shell/shell.qml ipc call chaves.omawin <method>`.

| Method | Does |
|--------|------|
| `open` / `close` / `toggle` / `show` / `hide` | the popup |
| `status` | one line: the painted state, the `vm-state.sh` line behind it and the bar tooltip, e.g. `stopped installed=1 docker=active pid= frozen= cores= ram= web=000 cid= started= \| Windows VM · STOPPED · 4 cores · 16G` |
| `fail <text>` | **debug.** Paints the failed card with `<text>` as the message, without breaking anything to get there. Sticky like a real failure — cleared by the next successful action or state change, or at once with `fail ""`. |
| `mock <line> [probe] [action]` | **debug.** Stands `<line>` in for `vm-state.sh`, `probe` (`ok`/`no`) in for the RDP probe and `action` (`start`/`stop`) in for a pending transient, so every face of the card can be looked at with the VM switched off. `mock "" "" ""` (all three arguments are required by the IPC) hands the widget back to the real sampler and drops the mocked transient. |

The two debug methods only paint: a mocked line never reaches the cache file
and neither method runs a command. Text given to them is capped and stripped
of control characters like any helper output.

### Test hooks

The helpers read a few environment variables so the tests can point them at
fixtures: `PROC_ROOT`, `SYS_ROOT`, `COMPOSE_FILE`, `CREDENTIALS_FILE`,
`DOCKER_STATE`, `WEB_CODE` for `vm-state.sh`; `RDP_HOST`, `RDP_PORT`,
`RDP_TIMEOUT`, `RDP_PROTOCOLS` for `rdp-probe.sh` (shape-checked, the probe
refuses anything but a dotted IPv4 address); `POLKIT_RULES_DIR` and
`SETUP_SKIP_ROOT_CHECK` for `setup`. Nothing selects a program to run: the
unit name and every command line are constants.

### Layout

- `helpers/vm-state.sh`, `helpers/rdp-probe.sh` and the pure state machine in
  `lib/State.js`, with `node --test tests/` over all three. The sampler also
  reports `started=`, the QEMU process's start time in epoch seconds, read
  from `/proc/<pid>/stat` field 22 and `/proc/stat`'s `btime` — no `ps`, no
  fork — which is where "Uptime" comes from.
- `Service.qml` — the 5 s/30 s state sampler, the 3 s/30 s RDP probe, the
  transients, the sticky failure, and the actions: Start and Connect through
  `helpers/launch.sh` (the transient user unit `omawin-launch`) with the
  outcome read back by `helpers/launch-result.sh`, Stop through
  `omarchy-windows-vm stop`, Pause/Resume through
  `pkexec /usr/bin/docker pause|unpause omarchy-windows`, Web viewer and
  Shared folder through `xdg-open`, Install through Omarchy's
  floating-terminal wrapper — plus the cache.
- `Panel.qml` — the bar glyph (state by colour, a pause badge, a pulse while
  the VM is coming up or going down, `bar.urgent` on a failure, the state,
  the VM's shape and its uptime in the tooltip, middle click =
  Start/Connect) and the popup card: one face per state, drawn with the
  shell's own `PopupCard`/`PanelHero`/`Button` kit.
- `polkit/49-omawin.rules.in`, `polkit/49-omawin-probe.rules.in` and `setup`
  — the rule that makes the cycle passwordless, its probe, and the script that
  shows and installs them.

MIT licensed.
