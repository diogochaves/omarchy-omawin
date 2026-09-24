# Changelog

What changed in each version of Omawin, newest first. `omarchy plugin update
chaves.omawin` brings you the latest.

## Unreleased

### Fixed

- **Copy password no longer saves the password in Omarchy's clipboard
  history.** It is now marked as sensitive, so the history skips it. If you
  used Copy before this update, open the clipboard history and delete that
  entry. It is kept in `~/.local/state/omarchy/clipboard-history.json`.
- The clear 30 s after Copy no longer erases something you copied in the
  meantime: it only clears the clipboard if the password is still on it.

### Changed

- The bar glyph's pulse, while the VM starts or stops, now costs a fraction of
  the GPU it used to: the same breath, drawn at 12.5 frames a second instead of
  every monitor refresh.

## 0.2.0 — 2026-09-13

First public release. An Omarchy bar widget for Omarchy's Windows VM that works
without the Docker socket or the `docker` group.

### Added

- One glyph in the bar, coloured by state: stopped, starting, booting, ready,
  paused, failed. It pulses while the VM comes up or goes down and shows a badge
  while paused. Middle click starts or connects.
- A card with one face per state: Start, Connect, Pause, Resume, Stop, Web
  viewer, Shared folder, Install.
- Pause closes the RDP window first, then freezes the VM; Resume unfreezes it and
  reopens the window in one press; Stop on a paused VM unpauses it first so
  Windows shuts down cleanly.
- **Tune**: cores, RAM and disk (grow only) while the VM is off, with one
  authorisation and the login left untouched.
- **Login**: the stored RDP username and password. Reveal for 15 s, copy for
  30 s, and Update password after changing it inside Windows.
- **Settings**: turn the optional polkit rule on and off. It allows exactly five
  command lines for one user and makes Start, Stop, Pause and Resume
  passwordless; Tune and Update password keep asking.
