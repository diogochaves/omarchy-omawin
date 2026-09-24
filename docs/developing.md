# Developing

Run it from a checkout instead of `plugin add`:

```sh
ln -s "$PWD" ~/.config/omarchy/plugins/chaves.omawin
omarchy-shell shell rescanPlugins
omarchy bar put chaves.omawin --before omarchy.power
```

`shell.json` hot-reloads, so the glyph appears at once; a changed `Panel.qml`
needs `omarchy restart shell`. Everything about the layout goes through
`omarchy bar` — never hand-edit `shell.json`. `node --test tests/` runs the
sampler, the probe, the state machine, the tune and credentials helpers and
`setup`, all unprivileged, against fixtures: `tests/fixtures/generate.sh`
rebuilds the fake `/proc`, `/sys`, compose, credentials and the sparse
`data.img` those use (that image is `.gitignore`'d — git would store all 64 GiB
of it — and the tests create it themselves if it is missing). They also run
`tests/shellcheck.sh`, ShellCheck over every tracked shell script (skipped if
`shellcheck` is not installed).

## IPC

`omarchy-shell chaves.omawin <method> [args]`, or
`qs -p /usr/share/omarchy/shell/shell.qml ipc call chaves.omawin <method>`.

| Method | Does |
|--------|------|
| `open` / `close` / `toggle` / `show` / `hide` | the popup |
| `status` | one line: the painted state, the `vm-state.sh` line behind it and the bar tooltip, e.g. `stopped installed=1 docker=active pid= frozen= cores= ram= web=000 cid= started= disk=64G login=chaves \| Windows VM · STOPPED · 4 cores · 16G · 64G` |
| `fail <text>` | **debug.** Paints the failed card with `<text>` as the message, without breaking anything to get there. Sticky like a real failure — cleared by the next successful action or state change, or at once with `fail ""`. |
| `mock <line> [probe] [action]` | **debug.** Stands `<line>` in for `vm-state.sh`, `probe` (`ok`/`no`) in for the RDP probe and `action` (`start`/`stop`) in for a pending transient, so every face of the card can be looked at with the VM switched off. `mock "" "" ""` (all three arguments are required by the IPC) hands the widget back to the real sampler and drops the mocked transient. |
| `face <name>` | **debug.** Shows one face of the card — `live`, `tune`, `login`, `updatePassword` or `settings` — seeded the way a press would seed it, so the sub-faces can be looked at (and screenshotted) without pressing through to them. Anything else means `live`. The two faces that rewrite the compose still close themselves when the VM is not stopped. |

The three debug methods only paint: a mocked line never reaches the cache file
and none of them runs a command. Text given to them is capped and stripped
of control characters like any helper output.

## Test hooks

The helpers read a few environment variables so the tests can point them at
fixtures: `PROC_ROOT`, `SYS_ROOT`, `COMPOSE_FILE`, `LEGACY_COMPOSE_FILE`, `CREDENTIALS_FILE`,
`DOCKER_STATE`, `WEB_CODE` for `vm-state.sh`; `RDP_HOST`, `RDP_PORT`,
`RDP_TIMEOUT`, `RDP_PROTOCOLS` for `rdp-probe.sh` (shape-checked, the probe
refuses anything but a dotted IPv4 address); `DATA_IMAGE` for the disk reading;
`HOST_CORES`, `HOST_RAM_GB`, `FREE_GB`, `WINDOWS_DIR`, `TZ_NAME` and
`TUNE_DRY_RUN` for `tune.sh`; `CREDS_DRY_RUN`, `COPY_MARK`, `WL_COPY` and
`WL_PASTE` for `credentials.sh`;
`OMAWIN_STATE_DIR` for `rule-state.sh`; `POLKIT_RULES_DIR`,
`SETUP_SKIP_ROOT_CHECK`, `OMAWIN_STATE_DIR` and `SETUP_TARGET_HOME` for
`setup`. The two dry runs stop before the one `pkexec` call and print what they
would have piped into it, with the password replaced by `***`. Nothing selects
a program to run: the unit name and every command line are constants.

## Layout

- `helpers/vm-state.sh`, `helpers/rdp-probe.sh` and the pure state machine in
  `lib/State.js`, with `node --test tests/` over all three. The sampler also
  reports `started=`, the QEMU process's start time in epoch seconds, read
  from `/proc/<pid>/stat` field 22 and `/proc/stat`'s `btime` — no `ps`, no
  fork — which is where "Uptime" comes from, plus `disk=` (the apparent size of
  `~/.windows/data.img`) and `login=` (the credentials file's `USERNAME` line,
  never its password).
- `helpers/tune.sh` — `limits` for what the Tune face may offer (nproc,
  MemTotal, `df`, the current disk) and `apply` for the write: the writer's own
  regexes applied client-side first, then cores ≤ nproc, RAM ≤ MemTotal, the
  grow-only disk and the wizard's free-space rule, then one `pkexec` with the
  six fields on stdin.
- `helpers/credentials.sh` — `username`, `password`, `copy`, `clear` and
  `write`: the reads the Login face makes, and the rewrite, which does the
  compose first (that is the cancellable half) and then the credentials file,
  atomically, the way `omarchy-windows-vm` writes it.
- `helpers/rule-state.sh` — `present=/user=/since=` from the user-owned copy of
  the polkit rule, which is the only unprivileged way to know it is there.
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
  Start/Connect) and the popup card: one face per state plus the four
  sub-faces (`face`: Tune, Login, Update password, Settings), all drawn with
  the shell's own `PopupCard`/`PanelHero`/`Button`/`ToggleSwitch`/`TextField`
  kit. The two that rewrite the compose close themselves if the VM stops being
  stopped underneath them.
- `polkit/49-omawin.rules.in`, `polkit/49-omawin-probe.rules.in` and `setup`
  — the rule that makes the cycle passwordless, its probe, and the script that
  shows and installs them.
