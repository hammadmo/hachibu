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
  none during a Top Up, or the current level while sailing. It changes
  nothing.
- `LimitSetter` (Kit) carries out limit requests one at a time. Only the
  newest request counts, and a request is "held" only once macOS reports
  it (and, for a helper limit, once pmset enforces it).
- `BatteryMonitor` (app, main actor) reads the battery on a timer, asks
  the engine, hands requests to the setter, and decides what is saved as
  the user's limit and what the popover says. Views read only from it.
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
- Only the copy in the menu bar runs Top Up and sailing. A one-shot
  command-line run sets `runsModes = false`.
- A command-line run puts the limit back before it calls
  `NSApp.terminate`, not from inside the quit.
- Hachibu never cuts the charger (`docs/research/charge-control.md`).
