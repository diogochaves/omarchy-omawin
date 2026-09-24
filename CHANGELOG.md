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
  meantime: it only clears the clipboard if the password is still on it, even
  if you changed the password with Update password in those 30 s.
- **A start or stop that takes too long now says so.** The card used to turn
  red with no explanation after 2 min 30 s (start) or 2 min 10 s (stop); it
  now says what timed out and what to try, and so does the bar tooltip.
- **Update password no longer undoes a disk grow you have not started yet.**
  After Tune made the disk bigger, saving a new password before the next start
  put the old disk size back, while the card still said the next start would
  grow it.
- **A VM installed with an older Omarchy no longer reads NOT INSTALLED.** Its
  settings were still in `~/.config/windows`, where Omarchy used to keep them,
  so the card offered Install, which would have run the setup wizard again. It
  now shows the VM as stopped, and the first Start finishes Omarchy's move of
  those settings (it may ask for your password once).
- **Cancelling Pause's password dialog now says what happened.** Pause closes
  the Windows window first; without the optional polkit rule it then asks for
  your password, and cancelling left the VM running with no window and no word
  about it. The card now says the VM is still running and to press Connect.

### Changed

- **After a start that grew the disk, the running card tells you how to use
  the new space.** Windows keeps C: at its old size until you extend it in
  Disk Management; before, the only mention was on Tune, before the start. The
  note appears after a grow made with Tune, and stays until you dismiss it
  with × or stop the VM.
- **Every card now has a Login… button**, last in its bottom row, so the RDP
  username and password are one click away in every state, including while
  the VM boots and the web viewer asks for them. Before, the only ways in were
  the Login line of the stopped card, which did not look clickable, and
  Settings. Shared folder moved to that bottom row too.
- **Back is now in one place on Tune, Login, Update password and Settings**: a
  ‹ at the top left of the title, where the face's icon was. It replaces the
  Back and Cancel buttons at the bottom, which sat in a different spot on each
  face, next to the main action.
  Back and Esc work while the VM starts, stops or pauses; they only wait
  while Tune or Update password is saving, so a typed password is not lost.
- **Esc goes back one step** from Tune, Login, Update password and Settings
  instead of closing the whole card. On the card itself it still closes it.
- The bar glyph's pulse, while the VM starts or stops, now costs a fraction of
  the GPU it used to: the same breath, drawn at 12.5 frames a second instead of
  every monitor refresh.
- **The open card uses far less GPU while the VM starts, boots or stops.** Its
  progress bar moves at 25 frames a second instead of redrawing on every
  monitor refresh, and only while the card is open; the Windows logo on the
  card no longer pulses beside it (the one in the bar still does). On a
  3440x1440 144 Hz screen, Hyprland's share of the GPU with the card open
  during a start went from about 47% to about 10%.

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
