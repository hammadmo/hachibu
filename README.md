<p align="center">
  <img src="docs/images/icon.png" width="128" height="128" alt="Hachibu icon">
</p>

<h1 align="center">Hachibu</h1>

<p align="center">
  <strong>Keep your MacBook's battery at the charge limit you choose.</strong><br>
  A native menu bar app for macOS 27.
</p>

<p align="center">
  <a href="https://github.com/hammadmo/hachibu/releases/latest"><img src="https://img.shields.io/badge/download-0.1-b8934a" alt="Download 0.1"></a>
  <img src="https://img.shields.io/badge/macOS-27-1d1a17" alt="macOS 27">
  <img src="https://img.shields.io/badge/Apple%20silicon-only-1d1a17" alt="Apple silicon only">
  <img src="https://img.shields.io/badge/Swift-6-b8934a" alt="Swift 6">
  <img src="https://img.shields.io/badge/license-MIT-b8934a" alt="MIT license">
</p>

<p align="center">
  <img src="docs/images/hero.png" width="664" alt="The Hachibu popover in dark and light mode: battery at 80%, holding at the limit">
</p>

The name comes from *hara hachi bu*: eat until you are eight parts full.
A battery kept below full lasts longer, so Hachibu stops charging before
it gets there.

Hachibu runs on your Mac only, with no account and no server. The one
thing it does on the network is ask GitHub, once a day, whether there is
a newer version. The request says which version of Hachibu you have,
nothing else, and you can switch the check off in Settings. It is free and open source.

## Why Hachibu

macOS can already stop charging at 80%, and for many people that is
enough. Hachibu is for when you want more than that: a limit below 80%,
a quick charge to full before a day out, less topping up while plugged
in, a pause when the battery is hot, and a record of what the battery
did. All of it is free.

There are good tools that do this already. How they compare, going by
each project's own page in November 2026:

| App | Price | Source | Limits | Runs on |
| --- | --- | --- | --- | --- |
| macOS itself | Free | Closed | 80 to 100% | macOS 26.4 and later |
| [batt](https://github.com/charlie0129/batt) | Free | Open, GPL-2.0 | 10 to 99% on macOS 27 | Many macOS versions; app and command line |
| [BatFi](https://micropixels.software/batfi/) | $15, once | Closed (older versions were open) | Any, below 80% included | macOS 14.8 and later |
| [AlDente](https://apphousekitchen.com/) | Free, with a paid Pro | Closed (an old version was open) | Below 80% included | macOS 12 and later |
| **Hachibu** | Free | Open, MIT | 20 to 100% | macOS 27 only |

Pick one of the others if you are on an older macOS or an Intel Mac, if
you want a command line or control of the MagSafe light (batt), limits
that change by time and place (BatFi), or a long-established app with
support (AlDente). Sailing, heat protection, Top Up, and calibration are
Pro features in AlDente; in Hachibu they are part of the app.

## Features

| Feature | What it does |
| --- | --- |
| **Charge limit** | Pick any limit from 20% to 100%. A limit is shown as set only after macOS reports that it holds it. |
| **Top Up** | Charge to 100% once, for a day away from the charger. Your limit returns when you unplug or press Stop. An optional keyboard shortcut starts one from any app. |
| **Sailing** | Let the battery drift a few percent below the limit before it charges again, instead of topping up all day. |
| **Heat protection** | Pause charging when the battery is hot (40 °C by default) and resume when it has cooled. |
| **Calibration** | A guided cycle meant to correct the percentage and health readings: drain to 15%, charge to 100%, rest for two hours. It takes about six hours. On a battery whose readings are already right it changes nothing. |
| **Power flow** | Watts from the charger, to the Mac, and into or out of the battery, with what the connected charger can supply at most, about how long charging will take, and a note when the charger cannot keep up with the Mac. |
| **History** | Level, temperature, power, and health over a day, a week, or a month, with the battery's capacity now and when new. Everything recorded can be exported as a CSV file. |
| **Notifications** | When the limit is not holding, when macOS starts a full charge of its own, and when a Top Up or a calibration finishes. Each can be switched off. |
| **Updates** | Hachibu checks for a newer version once a day and installs it when you agree. Every update is verified against Hachibu's signing key first. The check can be switched off. |

Limits below 80%, sailing, heat protection, and calibration need the
[helper](#how-it-controls-charging). Without it, Hachibu sets macOS's own
limits (80 to 100%) and runs Top Up.

## Screenshots

<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="docs/images/history-dark.png">
    <img src="docs/images/history-light.png" width="720" alt="The History window: battery level, temperature, power, and battery health over 24 hours">
  </picture>
</p>

<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="docs/images/settings-dark.png">
    <img src="docs/images/settings-light.png" width="520" alt="Settings, Charging tab: limit, sailing range, calibration, and heat protection">
  </picture>
</p>

The pictures show sample data, not a real battery.

## Requirements

- An Apple silicon MacBook running **macOS 27**.
- Intel Macs and earlier versions of macOS are not supported. The way
  charging is controlled changed in macOS 27, and Hachibu only knows the
  new way.

## Install

1. Download `Hachibu-0.1.zip` from the
   [latest release](https://github.com/hammadmo/hachibu/releases/latest)
   and unzip it.
2. Move `Hachibu.app` to your Applications folder and open it. It lives
   in the menu bar; there is no Dock icon.
3. For limits below 80%, sailing, heat protection, and calibration,
   install the helper from Settings > Helper and allow it once in
   System Settings > General > Login Items.

The download is signed with a Developer ID and notarized by Apple.

To build Hachibu from source or work on it, see
[docs/BUILDING.md](docs/BUILDING.md).

## How it controls charging

Hachibu never switches charging on or off itself. It asks macOS to hold
a limit, in one of two ways.

**1. macOS's own limit, no helper.** macOS 27 offers limits of 80, 85,
90, 95, and 100%. Hachibu sets these through the same private system
framework (PowerUI) that System Settings uses. They take effect at once.

**2. Any limit from 20%, with the helper.** For limits macOS does not
offer, a small helper that runs as root writes the limit into macOS's
charging settings, and macOS enforces it, usually within two minutes
(26 to 90 seconds when measured here). You install the helper from Settings >
Helper and approve it once in System Settings > General > Login Items.

The helper accepts three requests and nothing else: set a limit,
reconnect the charger (to undo a cut left by another tool; Hachibu never
makes one), and report its status. It listens only to a copy of Hachibu
signed by the same Apple developer team as the helper itself, and it
quits by itself ten seconds after the app lets go.

The whole helper is one short file,
[`Sources/HachibuHelper/main.swift`](Sources/HachibuHelper/main.swift),
about 150 lines. If you are deciding whether to let it run as root, read
it: it takes a few minutes.

### Check your download

The release notes give the zip's SHA-256. To check it, and to see who
signed the app and that Apple notarized it:

```bash
shasum -a 256 ~/Downloads/Hachibu-0.1.zip
```

```bash
spctl -a -vv /Applications/Hachibu.app
```

```bash
codesign -dv --verbose=2 /Applications/Hachibu.app
```

`spctl` should say `accepted` and `source=Notarized Developer ID`, and
`codesign` should list `Authority=Developer ID Application: Mohamed Hammad`.

### Good to know

- With the limit below the current level and the charger connected,
  macOS drains the battery down to the limit by itself. That drain
  appears to stop while the Mac sleeps.
- macOS starts charging again once the level is more than about 5%
  below the limit.
- From time to time macOS charges to 100% on its own to keep its
  estimates accurate. Hachibu cannot stop that; it tells you when it
  happens.
- On battery, macOS sets the limit aside and takes it up again when the
  charger is connected.
- Hachibu does not cut the charger, and the helper cannot. An earlier
  version tried this for a "discharge" mode; on macOS 27 it could leave
  the Mac running on battery while plugged in, so it was removed.
- Hachibu never keeps the Mac awake.
- Both ways rely on parts of macOS that Apple does not document, and a
  macOS update can break them. When a limit is not being held, Hachibu
  says so instead of showing the limit you asked for.

## Uninstall

1. In Hachibu, open Settings > Helper and click **Remove Helper…** and confirm. A
   limit macOS does not offer by itself moves up to the next one it does
   (60% becomes 80%, 82% becomes 85%), so nothing is left that only the
   helper set.
2. In Settings > General, switch off **Open at login**.
3. Quit Hachibu and delete `Hachibu.app` from your Applications folder.
4. To also remove your choices and history, delete
   `~/Library/Application Support/Hachibu` and run:

```bash
defaults delete app.hachibu.mac
```

The charge limit itself is a macOS setting. After uninstalling you can
change it in System Settings > Battery.

## Credits

The method for setting a charge limit on macOS 27 was worked out and
published by the [batt](https://github.com/charlie0129/batt) project.
Hachibu's code is its own, but it would not exist without what batt
documented.

Designed and built by Mohamed Hammad.

## License

[MIT](LICENSE)
