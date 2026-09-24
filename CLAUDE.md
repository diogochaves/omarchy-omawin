# omawin — instructions for agents

Omarchy bar widget (`chaves.omawin`) for Omarchy's Windows VM. QML (`Panel.qml`,
`Service.qml`), a pure state machine (`lib/State.js`), bash helpers (`helpers/`),
the polkit rule and its `setup`. The README is the user-facing reference; read its
"Under the hood" section before changing behaviour.

## `main` is the release channel

`omarchy plugin update` fetches the tip of `main` and fast-forwards to it; it
ignores tags and GitHub releases. **Anything pushed to `main` ships to every user
on their next update.** So:

- Work happens on a branch (`fixes-X.Y.Z`, `feature-…`), never directly on `main`.
- Never push, merge to `main`, tag or publish a release until the tests pass and
  Diogo has tested the exact candidate (in an omabox and on his own bar) and
  approved it.

## Every change gets a changelog line

`CHANGELOG.md` is the record users read: it is in the diff `omarchy plugin update`
shows them, and each GitHub release body is copied from it.

- Every fix or user-visible change adds a line under `## Unreleased`, **in the same
  commit** as the change. No changelog line, no commit.
- Write what the user notices, not what the code does: "Copy password no longer
  leaves the password in clipboard history", not "pass --sensitive to wl-copy".
- Group under `### Fixed`, `### Changed`, `### Added`, `### Removed` as needed.
- Pure refactors, test-only and comment-only changes may skip it; say so in the
  commit message.

## Releasing

1. Rename `## Unreleased` to `## X.Y.Z — YYYY-MM-DD` and start a fresh
   `## Unreleased` above it.
2. Bump the version in `manifest.json` **and** `pluginVersion` in `Panel.qml`.
3. Merge to `main`, tag `vX.Y.Z`, and create the GitHub release with that
   version's changelog section as its body.

## Working here

- Tests: `node --test tests/` — all unprivileged, against fixtures. Add a test for
  every fix the fixtures can reach.
- Visual and behaviour checks run in an omabox (load the `omabox` skill), then on
  the real bar. The debug IPC (`mock`, `fail`, `face`) reaches every card face
  without touching the VM; see the README's IPC table.
- The real VM may be started, stopped, tuned or removed for testing. Keep its RAM at
  8G or less.
- Fix one issue per commit, in the agreed order, so each can be tested alone.
