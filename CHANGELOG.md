# Changelog

What changed in each version of Omawin, newest first. `omarchy plugin update
chaves.omawin` brings you the latest.

## Unreleased

### Added

- **Back up VM… keeps a copy of Windows before you change it.** In Settings,
  with the VM off, it copies Windows' disk and login into
  `~/.windows.bak-<date>`: instant on btrfs, Omarchy's default, and a full
  copy with progress and Cancel elsewhere. The Remove face and Tune's
  "a disk can't shrink" line point to it. Restoring is by hand, as the README
  explains.

- **A key for Windows, shown on the card.** Settings › Key binding gives you
  the line to add to bindings.lua, with Copy line and Open bindings.lua.
  Once it's there, the stopped card and the tooltip show your key (say
  SUPER ALT W), which starts Windows, or connects when it's running.

- **Update login: pick which Windows account Connect uses.** Login ›
  Update login… (was Update password…) now has a username field too, so a
  restored backup or a second Windows account no longer needs a reinstall.
  Leave the password empty to keep the current one. It can't create or
  rename an account in Windows; it writes down one that already exists.

### Changed

- **Settings is shorter.** The Login, Helper and Compose lines are gone: Login
  has its own button on every card, and the two paths never change. The
  rule's command list folds behind "Show the rule", and the key binding line
  behind "Set up a key…".
- **The paused card says what Pause keeps.** Pause stops Windows using CPU
  but it still holds all of its RAM; the card and Pause's tooltip now say so,
  and that Stop is what frees it.
- **The stopped card only mentions Docker when it's down.** "Docker: active"
  is gone; when Docker isn't running the card says so in red, with the
  command that starts it, since Start can't work without it.
- **Tune offers RAM sizes in between, and warns before you starve Omarchy.**
  RAM goes 4, 6, 8, 12, 16, 24, 32, 48G (no more 2G, below Windows 11's
  minimum), only sizes that leave the machine 4 GB are offered, and above half
  of it the card says how much is left. Cores start at 2 and warn when Windows
  would get every thread. A 192G disk joins the list. Those warnings are in
  your theme's yellow.

## 0.2.4 — 2026-10-04

### Fixed

- **A removed VM no longer haunts the card.** After removing the VM, the card
  and its tooltip stopped showing the old VM's cores, RAM, disk and last run,
  and a fresh install no longer claims its disk grew.
- **Saving a password twice in a row works.** A second Update password in the
  same session used to fail with "must be 1 to 64 printable characters" until
  the bar restarted.
- **Passwords with accented letters work.** A VM installed with a password like
  "Pässwort1" could not use Reveal, Copy, Tune or Update password: Omawin
  called it unprintable, though Omarchy accepts it.
- **Tune can change cores and RAM on a nearly full drive.** The "disk + 10 GB
  free" rule now applies only when the disk grows.
- **Update password refuses a password Omarchy would cut short.** A password
  whose only "=" is its last character (like "Secret1=") was saved whole but
  sent without the "=", so Connect kept failing. It is now refused, with why.
- **A saved password no longer lingers in the card.** After Save, or when the
  card closed or the VM started, the typed password stayed in the hidden
  field: Enter saved it again and Tab stopped working until the next visit.
- **Another Windows container is no longer taken for Omarchy's VM.** With
  WinApps, WinBoat or another user's VM running, the card could show theirs
  as yours, and then fail to pause it.
- **Tune keeps the VM's own RAM size on offer.** A size set by hand (say 12G)
  vanished from the RAM choices as soon as another one was picked.
- **The docs no longer understate what Tune and Update password rewrite.**
  Both regenerate the VM's compose from Omarchy's template, so settings added
  to it by hand (keyboard, region, extra disks, USB) are dropped, not only by
  a reinstall.

### Added

- **On omarchy-console's rail**, Omawin now says itself whether the VM is
  running, starting or failed, so the rail no longer has to guess.
- **A key binding for Windows.** `omarchy-shell chaves.omawin primary` does
  what a middle click on the glyph does (Start when stopped, Connect when
  ready), so it can be bound to a key. The README shows how.
- **See what Windows is using.** The running card shows how busy its CPU is,
  and the stopped card how much of its disk Windows has really written.
- **A warning before Start when memory is short.** If the VM's RAM does not
  fit in what is free right now, Windows would quietly start with less than
  you set. The stopped card and Tune now say so first.
- **Remove the VM from the card.** Settings has a Remove VM… button while the
  VM is stopped. It lists what will be deleted (Windows, its disk and the
  saved login) and what stays (the Shared folder), reminds you to back up
  first, and then runs Omarchy's own remover in a terminal. Install… starts a
  fresh VM afterwards.

### Changed

- **Passwordless actions only skip the dialog at your desktop.** The polkit
  rule now applies to your active local session only, so an SSH login as you
  still gets the password prompt. A rule installed by an older Omawin keeps
  the old behaviour, and Settings says so: remove it and install it again.
- **Tune says how to get a smaller disk.** A disk can only grow, so under the
  greyed-out sizes Tune now explains that a smaller disk needs a new VM, with
  a link to Remove VM….

## 0.2.3 — 2026-10-01

### Fixed

- **Connect no longer fails silently when Windows rejects the login.** If the
  stored username or password is not the Windows account's (say, after
  restoring a backed-up VM), the card turns red and says so, instead of
  nothing happening. A locked-out account or an expired password gets its own
  message.

### Added

- The README explains how to restore a backed-up VM after reinstalling
  Omarchy, and how to remove the VM itself.

## 0.2.2 — 2026-09-25

### Changed

- **Back is now at the top right** of Tune, Login, Update password and
  Settings, where the gear is on the card, and the Windows logo stays in its
  place. Esc still goes back.
- Tune shows the VM's current cores, RAM and disk on its first line, as
  Current tuning.
- Settings names the plugin as Omawin 0.2.x, not by its ID chaves.omawin.
- The marketplace description now says Microsoft Windows 11, virtual machine
  and RDP, so searching for any of them finds Omawin.

### Fixed

- The settings gear on the card now lines up with the cores · RAM · disk box
  beside it, instead of sitting half a line lower.
- `sudo ./setup polkit --probe` no longer prints `__priv: command not found`,
  and its message names the one command line the probe rule allows again.

## 0.2.1 — 2026-09-24

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
  those settings. That Start asks for your password to move them, and a
  second time to start the VM unless you set up the optional polkit rule.
- **Cancelling Pause's password dialog now says what happened.** Pause closes
  the Windows window first; without the optional polkit rule it then asks for
  your password, and cancelling left the VM running with no window and no word
  about it. The card now warns that the VM is still running and to press
  Connect; the warning goes away once the window is open again.

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
  face, next to the main action. Back and Esc work while the VM starts,
  stops or pauses; they only wait while Tune or Update password is saving, so
  a typed password is not lost.
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
