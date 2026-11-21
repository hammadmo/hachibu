# Changelog

What changed in each version of Hachibu, newest first. Every version is
on the [releases page](https://github.com/hammadmo/hachibu/releases)
with its download.

## 0.4.1 (2026-11-21)

### Fixed

- **Heat protection acts sooner.** It pauses charging once the battery
  has been above the threshold for one minute, not three. macOS still
  takes a minute or two to stop charging after that.
- **Reopening Hachibu no longer starts that wait again.** The time the
  battery was already hot is read from what History recorded, so a
  restart or an update while the battery is hot does not delay the pause.

## 0.4 (2026-11-21)

### New

- **See charging at a glance.** The right end of the battery in the menu
  bar icon changes with the power source: the plain terminal on battery,
  two plug pins when the charger is connected but the battery is not
  charging (holding at the limit, for example), and a bolt while
  charging. "Charging" means current is going into the battery, the same
  reading the popover's status line uses.

## 0.3.1 (2026-11-20)

For people who use VoiceOver, Voice Control, or Switch Control.

### Fixed

- **The menu bar item says the battery level and the status.** It was
  announced as "Hachibu" only. It now reads, for example, "Hachibu,
  Battery 80 percent, Holding at limit".
- **Pressing the menu bar item through accessibility opens Hachibu.**
  That press did nothing. It now opens a window with what the popover
  shows: the level, the limit, Top Up, History, and Settings. A click
  with the pointer opens the popover as before.
- Upgrading with Homebrew no longer stops the helper from answering. If
  that happened to you going from 0.2 to 0.3, remove the helper and
  install it again in Settings > Helper.

## 0.3 (2026-11-20)

### New

- **The helper is offered the first time Hachibu opens.** A short dialog
  says what the helper adds (limits below 80%, sailing, heat protection,
  and calibration) and installs it when you agree. It is shown once, and
  only on a Mac that does not have the helper. Not Now closes it; the
  helper stays in Settings > Helper.
- Install with Homebrew: `brew install --cask hammadmo/tap/hachibu`.

## 0.2 (2026-11-20)

### New

- **Updates from inside the app.** Hachibu checks for a newer version
  once a day and installs it when you agree. Each update is verified
  against Hachibu's signing key. Switch the check off in Settings >
  General, or use Check for Updates… there.
- **What your charger can supply.** The power flow card names it, as in
  "65 W charger".
- **How long charging will take.** While charging, the status says about
  how long to your limit.
- **A weak charger is named.** When the charger is at its limit and the
  battery still drains, Hachibu says so.
- **"Top Up finished" notification**, and every notification switch now
  works.
- **Battery details in History**: capacity now, capacity when new, and
  cycles out of the design count.
- **Export**: History can save everything recorded as a CSV file.
- **A keyboard shortcut for Top Up** (⌃⌥⌘T), off until you switch it on.

### Fixed

- Setting a limit below 80% on battery no longer waits four minutes and
  then calls the limit "Set outside Hachibu".
- Removing the helper no longer leaves a limit macOS does not offer by
  itself, such as 82%.
- The Settings window no longer opens squeezed, and scrolls on a small
  screen.
- A sailing hold can no longer stay behind as the limit after a crash.

## 0.1 (2026-11-19)

The first release. Version 0.1 cannot update itself: download a later
version once and replace the app.

- A charge limit from 20% to 100%, shown as set only after macOS reports
  that it holds it.
- Top Up, sailing, heat protection, and a guided calibration.
- History charts for a day, a week, or a month.
- Notifications you can switch off one by one.
