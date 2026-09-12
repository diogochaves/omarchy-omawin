# Omawin

`chaves.omawin` is an Omarchy bar widget for Omarchy's Docker-based Windows
VM that needs no access to the Docker socket: status comes from `/proc`, a
cgroup freeze file and a TCP probe of the guest's RDP port, actions go through
Omarchy's own `omarchy-windows-vm` helper, and the few privileged calls are
meant to be auto-approved by a polkit rule scoped to their exact command
lines. Nobody has to join the `docker` group.

**Under construction.** Only the unprivileged sampler is here so far —
`helpers/vm-state.sh`, `helpers/rdp-probe.sh` and the state machine in
`lib/State.js`, with `node --test tests/` over all three. The widget itself
(`manifest.json`, `Service.qml`, `Panel.qml`) comes next.

MIT licensed.
