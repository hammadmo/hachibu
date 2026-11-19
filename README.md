# Hachibu

A menu bar app for macOS that keeps a MacBook's battery at the charge
limit you choose. The name is from *hara hachi bu*: eat until you are
eight parts full.

Hachibu runs on your Mac only. It has no account, no server, and sends
nothing anywhere.

## What it does

- **Charge limit.** Pick a limit from 20% to 100%. Hachibu shows a limit
  as set only after macOS reports that it holds it.
- **Top Up.** Charge to 100% once. Your limit returns when you unplug
  the charger or press Stop.
- **Sailing.** Let the battery drift a few percent below the limit
  before it charges again, instead of topping up all day.
- **Heat protection.** Pause charging when the battery is hot (40 °C by
  default), and resume when it has cooled.
- **Calibration.** A guided cycle meant to correct the battery's
  percentage and health reading: drain to 15%, charge to 100%, rest for
  two hours. Whether it changes the readings has not been measured yet.
- **History.** Charts of level, temperature, power, and health over a
  day, a week, or a month. The data stays in
  `~/Library/Application Support/Hachibu`.
- **Notifications** when the limit is not holding, when macOS starts a
  full charge of its own, and when a Top Up or a calibration finishes.
  Each can be switched off.

Limits below 80%, sailing, heat protection, and calibration need the
helper (see below). Without it Hachibu sets macOS's own limits and runs
Top Up.

## Supported Macs

- Apple silicon MacBooks on **macOS 27**. The app also opens on
  macOS 26, where it has never been tried.
- Developed and tested on one Mac: a MacBook Air (M1). Other models
  should work the same way but have not been tried.
- Not supported: Intel Macs and earlier versions of macOS. The way
  charging is controlled changed in macOS 27, and Hachibu only knows
  the new way.

## How it controls charging

Hachibu never switches charging on or off itself. It asks macOS to hold
a limit, in one of two ways.

1. **macOS's own limit, no helper.** macOS 27 offers limits of 80, 85,
   90, 95, and 100%. Hachibu sets these through the same private system
   framework (PowerUI) that System Settings uses. They take effect at
   once.
2. **Any limit from 20%, with the helper.** For limits macOS does not
   offer, a small helper that runs as root writes the limit into macOS's
   charging settings. macOS then enforces it within a few minutes
   (26 to 90 seconds when measured here). The helper is installed from Settings > Helper and needs
   your approval in System Settings > General > Login Items.

What follows from that:

- When the limit is below the current level and the charger is
  connected, macOS drains the battery down to the limit by itself. That
  drain appears to stop while the Mac sleeps.
- macOS starts charging again once the level is more than about 5%
  below the limit.
- From time to time macOS charges to 100% on its own to keep its
  estimates accurate. Hachibu cannot stop that. It tells you when it
  happens.
- Hachibu does not cut the charger, and the helper cannot. An earlier
  version tried this for a "discharge" mode; on macOS 27 it could leave
  the Mac running on battery while plugged in, so it was removed.
- Hachibu never keeps the Mac awake.
- Both ways rely on parts of macOS that Apple does not document. A
  macOS update can break them. When a limit is not being held, Hachibu
  says so instead of showing the limit you asked for.

The helper accepts three requests and nothing else (set a limit,
reconnect the charger, report its status), and only from a copy of
Hachibu signed by the same Apple developer team as the helper.

## Build

You need a Mac with macOS 27 and Xcode 26 or later (for Swift 6 and the
icon tools). There is no Xcode project; it is a Swift package.

```bash
./build.sh --open
```

This builds a release, signs it, installs `~/Applications/Hachibu.app`,
and opens it.

Signing decides what works:

- **No certificate (ad hoc):** the app works with macOS's own limits
  (80 to 100%). The helper cannot be installed.
- **An Apple Development certificate:** enough for the helper on your
  own Mac.
- **A Developer ID certificate:** needed to give the app to others.
  `./build.sh --notarize` also sends it to Apple's notary; first save a
  login with `xcrun notarytool store-credentials hachibu`.

Checks:

```bash
swift test --scratch-path ~/Library/Developer/Hachibu/test-build
```

```bash
tools/selftest.sh
```

`CLAUDE.md` and `ARCHITECTURE.md` describe the layout of the code and
the rules it follows. `docs/research/charge-control.md` records what was
measured about charging on macOS 27.

## Uninstall

1. In Hachibu, open Settings > Helper and click **Remove Helper…**. A
   limit macOS does not offer by itself moves up to the next one it
   does (60% becomes 80%, 82% becomes 85%), so nothing is left that
   only the helper set.
2. In Settings > General, switch off **Open at login**.
3. Quit Hachibu and delete `~/Applications/Hachibu.app`.
4. To also remove your choices and history, delete
   `~/Library/Application Support/Hachibu` and run:

```bash
defaults delete app.hachibu.mac
```

The charge limit itself is a macOS setting. After uninstalling you can
change it in System Settings > Battery.

## Credit

The method for setting a charge limit on macOS 27 was worked out and
published by the [batt](https://github.com/charlie0129/batt) project
(charlie0129/batt). Hachibu's code is its own, but it would not exist
without what batt documented.

## License

MIT. See `LICENSE`.
