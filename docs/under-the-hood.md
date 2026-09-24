# Under the hood

How Omawin works, what it touches, and why. For using it, see the
[README](../README.md).

## What it runs, reads and writes

- **Reads**, unprivileged: `/proc/<pid>/{comm,cgroup,cmdline,stat}` of the
  QEMU process to find it and its `-smp`/`-m`, `/proc/stat` for `btime`, the
  scope's `cgroup.freeze` under `/sys/fs/cgroup`, and whether
  `/var/lib/omarchy/windows/docker-compose.yml` and
  `~/.config/windows/credentials` exist (or, on an install from before Omarchy
  moved its compose, whether `~/.config/windows/docker-compose.yml` does: the
  first Start moves it, and until then the login is read from it). Plus `systemctl is-active
  docker.service`, `systemctl --user is-active omawin-launch` and, after a
  launch ends, the user journal of that one unit.
  For the shape and the login: the apparent size of `~/.windows/data.img`
  (`stat -c %s` — the compose is `root:docker 0640` and cannot be read, so that
  sparse file is the only readable record of `DISK_SIZE`), the `USERNAME` line
  of the credentials file on every sample and its `PASSWORD` line only when
  Reveal, Copy or Save asks, `nproc`, `MemTotal`, `df` of `~/.windows`,
  `timedatectl show -p Timezone`, and `~/.local/state/omawin/49-omawin.rules`
  — the copy `setup` leaves behind, which is how the Settings switch knows.
- **Network**: loopback only. A 19-byte X.224 Connection Request to
  `127.0.0.1:3389` and a request to `http://127.0.0.1:8006/` for its status
  code. Nothing leaves the machine.
- **Runs**: `/usr/bin/omarchy-windows-vm launch -k` inside the transient user
  unit `omawin-launch` (through `systemd-run --user`, so the RDP session
  survives a bar reload), `/usr/bin/omarchy-windows-vm stop`,
  `/usr/bin/omarchy-windows-vm install` in Omarchy's floating terminal,
  `/usr/bin/pkexec /usr/bin/docker pause|unpause omarchy-windows`,
  `systemctl --user stop omawin-launch`, and `xdg-open` on
  `http://127.0.0.1:8006` and `~/Windows`. Tune and Update password add
  `/usr/bin/pkexec /usr/bin/omarchy-windows-vm __priv write_compose` with the
  six `KEY=VALUE` lines on **stdin**; Copy password adds `/usr/bin/wl-copy --sensitive`
  and notes a SHA-256 of what it copied in `$XDG_RUNTIME_DIR/omawin/copied`
  (0600, tmpfs), and 30 s later `wl-paste` plus `wl-copy --clear` if the
  clipboard still holds exactly that; the Settings switch adds
  `sudo <plugin dir>/setup polkit [--remove]` in Omarchy's floating terminal.
  Every command is a constant with an absolute path; nothing is built from
  data, and no password is ever an argument — `/proc/<pid>/cmdline` is
  world-readable, so the password goes in on stdin or not at all.
- **Writes**: `$XDG_STATE_HOME/omawin/state.json` (see [Cache](#cache)),
  `~/.config/windows/credentials` when you save a new password (rewritten
  atomically, 0600, exactly as `omarchy-windows-vm` writes it), and
  `/var/lib/omarchy/windows/docker-compose.yml` — by asking root to, through
  the helper's own validated writer. `sudo ./setup polkit` writes the rule and
  a user-owned copy of it at `~/.local/state/omawin/49-omawin.rules`. None of
  your configuration is touched.
- **Privilege**: none of its own. `omarchy-windows-vm` calls pkexec itself for
  `__priv up_wait` and `__priv down`; pause, unpause and `write_compose` go
  through pkexec directly. The polkit rule is optional and installed by you, on
  purpose, from a terminal — and it does **not** cover `write_compose`, so Tune
  and Update password ask every time.

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
paused state whose window was already closed. Without the polkit rule the
authentication dialog only comes after the window has closed; cancelling it
leaves the VM running, and the card says so and points at Connect (reopening
the window by itself would mean a second dialog straight away).

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
{ "cores": 4, "ram": "16G", "disk": "64G", "started": 1789232550,
  "lastSeen": 1789236870124,
  "pending": { "cores": 6, "ram": "16G", "disk": "96G" },
  "grew": { "from": "64G", "to": "96G" } }
```

That is the whole file: the VM's shape, when the last seen run of it started
(epoch seconds), when it was last seen running (epoch milliseconds), and —
only after a Tune — the shape the next start will use. It is what the stopped
card's `4 cores · 16G · 64G` pill, its Cores/RAM/Disk readings and its "Last
run" print — nothing else reads it and nothing else writes it. Deleting it is
safe: those readings go blank until the VM next runs, and the pill falls back
to what the sampler can see. It is rewritten when the shape changes and at most
once a minute otherwise.

`pending` is there because nothing else can tell you what a stopped VM will
start as: the compose that holds it is `root:docker 0640`. It is written by
Tune's Apply, shown as `next start 6 cores · 16G · 96G` in the tooltip, and
dropped again the moment QEMU appears — at which point the live sample is the
truth. `disk` is only a fallback for `~/.windows/data.img`, which is readable
whether or not the VM runs.

`grew` is written when a start consumes a `pending` disk bigger than the one
the VM last ran with. It is what the running card's "extend C:" note reads,
kept for that one run (and `"dismissed": true` once its × is pressed), and
dropped by the next start.

## Tuning the VM

What a "normal" VM offers and how to get it here, as far as Omarchy's helper
allows. The first three rows are the widget's **Tune** face now; the rest still
is not widget work, and it does not pretend otherwise:

| Want | How, here | Notes |
|------|-----------|-------|
| Change cores / RAM (VM off) | **Tune…** on the stopped card | Cores up to `nproc`, RAM from the installer's own list up to `MemTotal`. Apply pipes `RAM= CORES= DISK= USERNAME= PASSWORD= TZ=` into `pkexec omarchy-windows-vm __priv write_compose` — the single privileged action the `install` wizard itself ends on — with the login read out of `~/.config/windows/credentials` and passed back unchanged, so the guest account is never touched and nothing is re-downloaded. One authorisation. The new shape is consumed by the next Start, which is why the face exists only while the VM is off; until then the pill reads `next start …`. `omarchy-windows-vm install` still works and still re-asks everything, starts the VM immediately and opens the browser. |
| Change cores / RAM (VM on) | Not possible | No hotplug headroom in `-smp` (no `maxcpus`), no balloon device, and the QEMU monitor is `unix:/run/shm/monitor.sock` inside the container. Stop, change, start. |
| Grow the disk | **Tune…**, a bigger Disk chip | Grow only — dockur refuses to shrink `data.img`, so smaller sizes are dead on the card. Needs `DISK+10 GB` free, computed without subtracting the existing image, which is the wizard's own rule. Windows sees the extra space as unallocated: extend `C:` in Disk Management once it is up (right-click `C:`, **Extend Volume**). The running card reminds you after the start that grew it, until you dismiss it. If Extend Volume is greyed out, a Recovery partition sits between `C:` and the free space and has to be moved or deleted first. |
| Change the RDP password | **Login › Update password…** | Only after you have changed it *inside* Windows: this writes down what the machine sends, it cannot rename or re-password a Windows account. Rewrites the credentials file and, in the same breath, the compose's fallback copy of it — so stopped only, one authorisation. |
| Anything else dockur supports (KEYBOARD, REGION, LANGUAGE, DISK2_SIZE, extra ports, `/dev/bus/usb`, DHCP/macvlan networking) | `sudo` edit of `/var/lib/omarchy/windows/docker-compose.yml`, then stop/start | `assert_mounts_safe` only checks owner/mode, the two bind lines and `PROTECT`; extra keys survive. **The next `install` run overwrites them.** Keep a copy. |
| Snapshot / rollback (VM off) | `cp -a --reflink=always ~/.windows ~/.windows.snap-<date>` | On btrfs a reflink copy is instant and free until blocks diverge. Rollback = copy back while stopped. User-owned, no root. |
| Suspend to RAM | Pause | A cgroup freeze; see [Pause and Resume](#pause-and-resume). The guest clock resyncs on resume. |
| Suspend to disk | Not from outside | `savevm` needs qcow2 and the monitor. Windows' own Hibernate from inside the guest is untested. |
| Second VM | Not with the helper | Own compose, other ports, outside Omarchy. |
| Autostart at login | Not by default | Possible with the polkit rule plus a user unit that runs `omarchy-windows-vm launch -k`. |
| Logs / console | Web viewer on 8006 | `docker logs` needs the socket. |

## Polkit rule

Optional, and now a switch: **Settings** on the card (the gear in its title)
shows the rule in full, says whether it is installed and for whom, and turns it
on or off by running `sudo <plugin dir>/setup polkit [--remove]` in Omarchy's
floating terminal — where `sudo` asks once and the file is printed before it is
written. Nothing about that is quiet or automatic: a plugin install cannot and
should not write to `/etc`.

The widget works without it — every action just raises Omarchy's authentication
dialog. `polkit/49-omawin.rules.in` is rendered with `@USER@` filled in, shown
to you in full, and only then installed as
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

**`write_compose` is deliberately left out**, even though Tune and Update
password use it. Rewriting the VM's configuration is rare and worth a dialog:
the rule is meant to make the start/stop cycle pleasant, not to hand every
process running as you a promptless way to rewrite what a root-invoked
`docker compose up` will consume. `setup polkit` even prints the two commands
to check that with, and the second one must still prompt.

Because that rules directory cannot be read as the user — no listing, no
`test -f`, and `pkcheck --detail` refuses an unprivileged caller — `setup` also
writes a user-owned copy of exactly what it installed to
`~/.local/state/omawin/49-omawin.rules` (0644) and deletes it on `--remove`.
The Settings switch is the presence of that copy; the user named inside it and
its mtime are the card's "Installed for X on <date>". It is a record, not the
truth: a rule removed by hand leaves the copy behind, which is why the card
says *as recorded by setup* and the first prompted action makes it obvious.

**Upgrading from 0.1.x with the rule already installed:** that copy does not
exist yet, so the switch reads as off. Press **Install rule…** once (or run
`sudo <plugin dir>/setup polkit`): the rule is rewritten unchanged and the copy
appears. Until then the only effect is the wrong switch; the actions are
already passwordless.

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
removed by `omarchy plugin remove`: see [Remove](../README.md#remove).
