# Omawin

`chaves.omawin` is an Omarchy bar widget for Omarchy's Docker-based Windows
VM that needs no access to the Docker socket: status comes from `/proc`, a
cgroup freeze file and a TCP probe of the guest's RDP port, actions go through
Omarchy's own `omarchy-windows-vm` helper, and the few privileged calls are
auto-approved by an optional polkit rule scoped to their exact command
lines. Nobody has to join the `docker` group.

## Status

Phases 1 to 3 are in: the sampler, the widget and the polkit rule.

- `helpers/vm-state.sh`, `helpers/rdp-probe.sh` and the pure state machine in
  `lib/State.js`, with `node --test tests/` over all three.
- `Service.qml` — the 5 s/30 s state sampler, the 3 s/30 s RDP probe, the
  transients, the sticky failure, and the actions: Start and Connect through
  `helpers/launch.sh` (the transient user unit `omawin-launch`, so the RDP
  session survives a bar reload) with the outcome read back by
  `helpers/launch-result.sh`, Stop through `omarchy-windows-vm stop`, Install
  through Omarchy's floating-terminal wrapper.
- `Panel.qml` — the bar glyph (state by colour, a pause badge, a pulse while
  the VM is coming up or going down, `bar.urgent` on a failure, the state in
  the tooltip, middle click = Start/Connect) and the popup card: one face per
  state, drawn with the shell's own `PopupCard`/`PanelHero`/`Button` kit.
- `polkit/49-omawin.rules.in` and `setup` — the rule that makes the cycle
  passwordless, and the script that installs it.

Not yet, and drawn disabled where the card has a place for them: Pause,
Resume, Web viewer, Shared folder, the cores/RAM cache behind a stopped VM's
pill, "Last run" and "Uptime" (phase 4).

## Try it

```sh
ln -s ~/code/omarchy-omawin ~/.config/omarchy/plugins/chaves.omawin
omarchy-shell shell rescanPlugins
omarchy bar put chaves.omawin --before omarchy.power
```

`shell.json` hot-reloads, so the glyph appears at once. Placement is
`omarchy bar move chaves.omawin --section right --index 0` and everything
else about the layout goes through `omarchy bar` too — never hand-edit
`shell.json`.

### IPC

`omarchy-shell chaves.omawin <method> [args]`, or
`qs -p /usr/share/omarchy/shell/shell.qml ipc call chaves.omawin <method>`.

| Method | Does |
|--------|------|
| `open` / `close` / `toggle` / `show` / `hide` | the popup |
| `status` | one line: the painted state plus the `vm-state.sh` line behind it, e.g. `stopped installed=1 docker=active pid= frozen= cores= ram= web=000 cid=` |
| `fail <text>` | **debug.** Paints the failed card with `<text>` as the message, without breaking anything to get there. Sticky like a real failure — cleared by the next successful action or state change, or at once with `fail ""`. |
| `mock <line> [probe] [action]` | **debug.** Stands `<line>` in for `vm-state.sh`, `probe` (`ok`/`no`) in for the RDP probe and `action` (`start`/`stop`) in for a pending transient, so every face of the card can be looked at with the VM switched off. `mock "" "" ""` (all three arguments are required by the IPC) hands the widget back to the real sampler and drops the mocked transient. |

## Polkit rule

Optional. The widget works without it — every action just raises Omarchy's
authentication dialog. `polkit/49-omawin.rules.in` is installed as
`/etc/polkit-1/rules.d/49-omawin.rules` with `@USER@` filled in, and says YES
to exactly five command lines for exactly one user:

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

Check first what pkexec actually puts in the action details on your box, then
install:

```sh
sudo ./setup polkit --probe                  # logs the details, grants nothing
pkexec /usr/bin/omarchy-windows-vm __priv status   # answer or cancel
journalctl -u polkit --since -5min --no-pager | grep omawin-probe
sudo ./setup polkit                          # the real rule; drops the probe
```

`program=` and `command_line=` in that log line must be the resolved path and
the full command line — that is what the rule matches on. Then verify, as the
user:

```sh
pkexec /usr/bin/omarchy-windows-vm __priv status              # no dialog
pkexec /usr/bin/omarchy-windows-vm __priv write_compose </dev/null  # prompts
```

`sudo ./setup polkit --status` says which rules are installed and who the
real one names; `sudo ./setup polkit --remove` takes both back out.

MIT licensed.
