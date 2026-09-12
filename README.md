# Omawin

`chaves.omawin` is an Omarchy bar widget for Omarchy's Docker-based Windows
VM that needs no access to the Docker socket: status comes from `/proc`, a
cgroup freeze file and a TCP probe of the guest's RDP port, actions go through
Omarchy's own `omarchy-windows-vm` helper, and the few privileged calls are
meant to be auto-approved by a polkit rule scoped to their exact command
lines. Nobody has to join the `docker` group.

## Status

Phases 1 and 2 are in: the sampler and the widget.

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

Not yet, and drawn disabled where the card has a place for them: Pause,
Resume, Web viewer, Shared folder, the cores/RAM cache behind a stopped VM's
pill, "Last run" and "Uptime" (phase 4), and the polkit rule that makes the
whole cycle passwordless (phase 3 — without it every action raises Omarchy's
own authentication dialog, which is the expected behaviour for now).

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

MIT licensed.
