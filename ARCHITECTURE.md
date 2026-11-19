# Architecture

`CLAUDE.md` has the folder layout and the commands. This file says how the
parts depend on each other and where behavior can be swapped.

## Targets and direction

```text
HachibuKit      rules and state machines; Foundation only; all unit tests
HachibuSystem   C and Objective-C: the battery controller (SMC) and PowerUI
Hachibu         the app: SwiftUI views, BatteryMonitor, the design kit
HachibuHelper   the root helper
```

`Hachibu` and `HachibuHelper` depend on `HachibuKit` and `HachibuSystem`.
Neither of those depends on anything else in the project. Rules go in
`HachibuKit` so they can be tested without the app.

## Who decides, who acts

- `ChargeEngine` (Kit) decides which limit macOS should hold: the user's,
  none during a Top Up, 15% and then none during a calibration, or a level
  to hold while sailing or while the battery is hot. It composes three
  rules, each with its own state (`ChargeRules.swift`): `SailingRule`,
  `CalibrationRule`, `HeatRule`. It changes nothing.
- `LimitOverride` (Kit) remembers the user's limit while a mode has
  macOS holding another one, until macOS confirms it is back.
- `ModeCoordinator` (Kit) is everything between the two above and one
  request to macOS: when to ask, what a failed request means, when the
  user's limit counts as back, what to write down for the next launch
  (`ModeRecord`), what a launch does with a leftover, and what a change
  made outside Hachibu ends. It takes events and returns effects
  (`ModeEffect`); it does none of them itself.
- `LimitSetter` (Kit) carries out limit requests one at a time. Only the
  newest request counts, and a request is "held" only once macOS reports
  it (and, for a helper limit, once pmset enforces it).
- `BatteryMonitor` (app, main actor) reads the battery on a timer, feeds
  the coordinator, carries out its effects (`carryOut`), handles the
  limits the user sets, and decides what the popover says. Views read
  only from it.
- `HistoryStore` (Kit) keeps samples in two append-only files;
  `HistorySeries` turns them into what a chart draws. `HistoryCenter`
  (app) records one sample a minute from the monitor's readings and loads
  charts off the main thread.
- `HelperManager` installs, removes, and watches the helper.

## Seams

- `LimitSystem` (Kit): everything `LimitSetter` asks of the Mac. Two
  adapters: `MacLimitSystem` in the app (PowerUI, pmset, the helper) and
  `FakeMac` in the tests.
- `BatteryMonitor(fixture:)`: a monitor that shows fixed values and never
  touches anything real. Snapshot fixtures are in
  `BatteryMonitor+Preview.swift`.
- `HelperXPC` (Kit): the one message between the app and the helper. The
  request list in `HelperRequest` is closed.

## Rules that are easy to break

- `APP_STORE` set means nothing real is read for snapshots or changed at
  all. Every new write path checks `Store.isOverridden`.
- Only the copy in the menu bar runs Top Up and sailing, and records
  history. One-shot command-line runs do neither (`Launch.isOneShot`);
  `--try` runs a mode, so quit the menu bar copy before using it.
- A command-line run puts the limit back before it calls
  `NSApp.terminate`, not from inside the quit.
- Hachibu never cuts the charger (`docs/research/charge-control.md`).
- A mode writes down what it asked macOS for and the user's limit it
  stood in for (`ModeRecord`, kept by `Preferences.modeRecord`). The
  record is erased only when macOS confirms the user's limit. At launch a
  leftover is recognised only by an exact match with what macOS holds,
  never by guessing.
- A rule about modes goes in `ModeCoordinator` with a scenario test
  (`ModeCoordinatorTests`), never in the monitor.
