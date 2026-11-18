# Charge control on Apple silicon

Research for the battery app (name undecided). Done 2026-11-18.
[V] verified in a source, [K] from knowledge, [U] unverified, test first.
[D] measured on the target Mac (MacBook Air M1, MacBookAir10,1, macOS 27.2.1, firmware 20457.41.3).

Question: what makes the best battery charge-control app on the Mac, and how
can one still control charging on macOS 27?
Decision it informs: version-one features and the helper architecture.

## Findings

### The platform changed under every app in this category
- From macOS 27 beta 4 (firmware 20457.0.125.0.2) the SMC charge keys return
  `kIOReturnNotPrivileged` even for root. `CH0B/CH0C/CHTE` are listed with
  zero size; `bfF0/bfD0/bfE0` are gated. The gate is the private entitlement
  `com.apple.private.iokit.soc-limit`. Writes to `AppleSmartBattery` are
  blocked too. Reads still work.
  [V](https://github.com/charlie0129/batt/issues/152)
  [V](https://github.com/charlie0129/batt/blob/master/docs/compatibility.md)
- The target Mac runs firmware 20457.41.3, later than the gated build. [D]
  Whether the keys are gated on this exact Mac is untested. [U]
- Apps showed "limit reached" while the Mac charged to 100%. This is the
  category's worst failure.
  [V](https://macos-tahoe.com/blog/macos-27-battery-charge-limit-apps-broken-aldente-batt-charging-to-100-fix-2026/) (secondary source)
- The 80% hold on the target Mac today is owned by `/usr/libexec/PowerUIAgent`
  with reason `manualChargeLimit` (`pmset -g battlimit`). So the limit in use
  is macOS's native mechanism. [D]

### Two backends still work on macOS 27 (both used by batt)
- **Native.** Load `/System/Library/PrivateFrameworks/PowerUI.framework`,
  create `PowerUISmartChargeClient` (`initWithClientName:`), call
  `setMCLLimit:error:`, `getMCLLimitWithError:`, `enableMCL:`, `disableMCL:`,
  `isMCLSupported`. Writing `mclLimitValue` to the root
  `com.apple.smartcharging.topoffprotection` domain and posting
  `com.apple.smartcharging.defaultschanged` allows 10–99%.
  [V](https://github.com/charlie0129/batt/blob/master/pkg/powerui/powerui.m)
- Native limits: upper limit only; macOS may drain toward the target while
  plugged in; Apple's full-charge override still fires (about every 21 days);
  a new target takes 2–6 minutes; after about 5 minutes on battery macOS
  withdraws the limit and restores it on plug-in. It persists through sleep
  and after the app quits.
  [V](https://github.com/charlie0129/batt/pull/175)
  [V](https://github.com/charlie0129/batt/pull/166)
- **Adapter cut.** `CHIE` (00 = adapter on, 08 = off) is not gated on 27.
  A root daemon can run its own loop: cut wall power at the upper bound,
  restore at the lower bound. Works only while the daemon is awake.
  [V](https://github.com/charlie0129/batt/blob/master/docs/compatibility.md)
- The native backend and the System Settings slider share one setting: last
  writer wins. powerd keeps policies in `com.apple.powerd.charging`.
  [V](https://github.com/charlie0129/batt/pull/176)
- No app can hold a limit while an Apple silicon Mac is shut down.
  [V](https://github.com/mhaeuser/Battery-Toolkit)

### Reading data
- SMC reads need no root: `IOServiceOpen("AppleSMC")`,
  `IOConnectCallStructMethod` selector 2 (cmd 9 key info, 5 read, 6 write). [K]
- Power keys: `PDTR` DC-in power, `PPBR` battery power, `B0AV`/`B0AC`,
  `VD0R`/`ID0R`.
  [V](https://github.com/charlie0129/batt/blob/master/pkg/smc/consts_arm64.go)
  `PSTR` system power. [K][U]
- `AppleSmartBattery` gives CycleCount, Temperature, Voltage, Amperage,
  IsCharging, ExternalConnected, `ChargerData.NotChargingReason`. On macOS 27
  capacities live in the `BatteryData` dictionary (`AppleRawMaxCapacity` 3556,
  `DesignCapacity` 4382 on the target). [D]

### Helper
- `SMAppService.daemon` fails with ad-hoc signing; it needs an Apple-issued
  identity. [V](https://developer.apple.com/forums/thread/799910)
- batt installs a plist in `/Library/LaunchDaemons` and talks over a
  root-owned Unix socket.
  [V](https://github.com/charlie0129/batt/blob/master/hack/cc.chlc.batt.plist)
- Launch at login: `SMAppService.mainApp.register()`; ad-hoc signing
  untested. [U]

### On the target Mac
- AlDente Pro (Setapp) and its helper
  `com.apphousekitchen.aldente-pro-setapp.helper` are installed and
  running. [D] They must be quit before testing.
- The MacBook Air M1 has no MagSafe, so LED control does not apply. [K]

### Market
- Apple's built-in Charge Limit (Tahoe 26.4+): free, 80–100% in 5% steps,
  Shortcuts support, occasional full charge. [V](https://support.apple.com/102338)
- "MacBook Battery Monitor" from the comparison table could not be found in
  three searches. The nearest match is Battery Monitor by Bresink, a
  monitor with no charge control. [U]

| App | Price | Platform | Status | Headline |
| --- | --- | --- | --- | --- |
| AlDente | Free; Pro €11.49/yr or €23.99 lifetime | Intel + Apple silicon | Active, 1.40.1 | Limit, discharge; Pro: sailing, heat protection, calibration, power flow, schedules |
| BatFi | $15 one time | Apple silicon, 14.8+ | Active, v4 | 50–100% limit, time and location rules, top up, heat pause, hotkeys |
| Juicy | Free; Pro $9.99 lifetime | unclear | Active, 1.6.2 | Alerts, health, watts, widgets; limit only in direct build |
| batt | Free, GPL-2 | Apple silicon | Active | Upper and lower limit, adapter cut, CLI + GUI |
| BattOpt | Free; Pro $5.99 | Intel + Apple silicon | Active (May 2026) | Limits, scheduled calibration, Wi-Fi location limits |
| Battery Toolkit | Free, BSD-3 | Apple silicon | Archived Mar 2026 | Upper and lower limits, adapter off |
| OpenDente | Free, GPL-3 | Apple silicon | Hobby, no releases | Limit, sailing, discharge, heat protection |
| macOS built-in | Free | Apple silicon, 26.4+ | Apple | 80–100% slider |

## Likes and dislikes

| App | People like | People dislike | Sources |
| --- | --- | --- | --- |
| AlDente | Keeps health near 100% on always-plugged Macs; easy UI with power detail; extras macOS lacks (sailing, heat protection, calibration, discharge) | Limit does not hold (issue #1846, 84 comments); free tier charges to 100% in sleep; clamshell sleep and display drops; helper prompts at every boot, duplicate background items on 27; breaks after macOS updates | [Setapp reviews](https://setapp.com/apps/aldente-pro/customer-reviews), [issues](https://github.com/AppHouseKitchen/AlDente-Battery_Care_and_Monitoring/issues) |
| BatFi | Feels native; cheaper than AlDente Pro; sleep options; v4 limits below 80% on macOS 27 | Breaks after macOS updates; "stuck on Initializing"; moved from free to paid; settings reset on sleep/wake; uninstall leaves an extension | [issues](https://github.com/rurza/BatFi/issues), [AlternativeTo](https://alternativeto.net/software/batfi/about) |
| Juicy | Clean modern design; custom alerts at any percentage; other devices' battery levels; one-time price | Health % differs from System Settings; no recalibration; few icon themes; blank icon on some displays | [Setapp reviews](https://setapp.com/apps/juicy/customer-reviews), [Product Hunt](https://www.producthunt.com/products/juicy-battery-app) |
| batt | Free and open; CLI and GUI over one daemon; upper and lower bounds; limit holds in sleep | Breaks on macOS and firmware changes; daemon and Homebrew install friction; native mode on 27 is upper-only | [issues](https://github.com/charlie0129/batt/issues?q=is%3Aissue) |
| BattOpt | Free scheduled calibration; location limits; shows equivalent CLI commands | No independent reviews found | [MacRumors thread](https://forums.macrumors.com/threads/battopt-pro-macbook-battery-utility-with-location-aware-charge-limits-clamshell-discharge.2481863/) |
| Battery Toolkit | Does one thing well; small daemon with minimal protocol | No Tahoe support; not notarized; disables sleep while charging; archived | [repo](https://github.com/mhaeuser/Battery-Toolkit) |
| OpenDente | Explains why charging is paused | No releases, tested on one Mac; no reviews found | [repo](https://github.com/killerk3emstar/OpenDente) |
| macOS built-in | Free, zero setup, survives sleep and updates | 80% floor; no sailing, discharge, or heat protection | [Apple](https://support.apple.com/102338) |
| Battery Monitor | Detailed data, history graphs, capacity aging log | Monitor only; old reviews | [App Store](https://apps.apple.com/us/app/battery-monitor/id413678017?mt=12) |

Patterns:
- Likes that repeat (must have): a limit below 80%, top up to 100%,
  discharge, live watts and health at a glance, a simple native popover,
  one-time or free pricing.
- Dislikes that repeat (our chance): a limit that silently fails, breakage
  after macOS updates, sleep and clamshell side effects, helper install and
  uninstall mess, cluttered UI.

## Feature matrix

| Feature | AlDente Pro | BatFi | batt | Version one? |
| --- | --- | --- | --- | --- |
| Charge limit below 80% | yes | 50–100% | 10–99% native | yes (native backend) |
| Truthful status (is current flowing, who holds the limit) | disputed | partial | CLI | yes |
| Top up to 100% | yes | yes | yes | yes |
| Discharge while plugged in | yes | yes | adapter cut | yes if `CHIE` probe passes |
| Sailing (lower bound) | yes | no | adapter mode | yes if `CHIE` probe passes |
| Health, cycles, temperature, watts | yes | yes | partial | yes |
| Heat protection | yes | above 40°C (not on 27) | no | later, needs probe |
| Calibration mode | yes | reminders | experimental | later |
| History charts | yes | no | no | later |
| Launch at login | yes | yes | yes | yes |
| Schedules, location rules | yes | yes | no | no |
| Global hotkeys, Shortcuts | Shortcuts | hotkeys | CLI | later |
| MagSafe LED | yes | no | yes | no (no MagSafe on target) |
| Clean uninstall that releases the limit | weak | weak | weak | yes |

## Decisions

1. Use the native PowerUI backend for the charge limit, because the SMC
   inhibit keys are gated on macOS 27 [V] and the target Mac already holds
   its limit natively [D]. Planned test: a probe that calls `isMCLSupported`
   and reads the current limit, then sets 75% and checks `pmset -g battlimit`.
2. Use adapter cut (`CHIE`) for discharge and sailing, because it is
   reported ungated [V]. Planned test: read `CHIE` key info without root;
   then, with the user's approval, one root write and a check that
   `ExternalConnected` flips.
3. Install the helper as a LaunchDaemon plist with a root-owned Unix socket
   and a peer check, because `SMAppService.daemon` needs an Apple-issued
   identity [V].
4. Show the measured state, never the intended one: amperage, who owns the
   limit, and a loud warning when the battery rises above the target,
   because a false "limit reached" is the category's worst failure [V].
5. Detect and take over or respect the System Settings slider and Optimized
   Charging, because the native backend shares their setting [V].
6. Apple silicon and macOS 27 only, because that is the only target.
7. Uninstall removes the daemon and releases the limit, because leftover
   helpers are a repeated complaint [V].

## Open questions

- Are `CHTE`/`bfF0` gated on this Mac? Test: key-info probe as user. [U]
- Does `CHIE` exist and accept a root write on the M1 Air on 27.2.1? [U]
- Does heat protection work on 27 (BatFi says no)? It could be built on
  adapter cut or by raising the native limit. Test after decision 2. [U]
- Does `SMAppService.mainApp` work ad-hoc signed? Test in the scaffold. [U]
- Is AlDente or the system slider the source of the current 80% limit?
  Ask the user; check System Settings > Battery. [U]
- Is `PSTR` readable on the M1 Air? Test: SMC read probe. [U]

## Probe results (2026-11-18, read-only, run as a normal user)

Probes: `probes/smc_probe.c`, `probes/powerui_probe.m`. No writes were made.

- Old charge keys are gone or gated on this Mac. `CH0B`, `CH0C`, `CHTE`,
  `CH0I`, `ACLC`: key not found (0x84). `bfF0`, `bfD0`, `bfE0`, `CH0J`:
  `kIOReturnNotPrivileged` (0xe00002c1). [D]
- `CHIE` exists: 1 byte, type `hex_`, attributes 0xd4, value 00 (adapter
  on). Readable as a user. A root write is untested. [D][U]
- PowerUI loads as a normal user. `isMCLSupported` = 1,
  `isMCLCurrentlyEnabled:` = 1, `getMCLLimitWithError:` = 80,
  `availableChargeLimitsWithError:` = 80, 85, 90, 95, 100,
  `isOBCSupported` = 1, smart charging off. Setters are untested. [D][U]
- The client also has `temporarilyDisableMCL:` and
  `temporarilyOverrideMCLTargetSoC:error:` (candidates for top up), and
  `fullChargeDeadline:`. [D]
- Readings work without root: `PSTR` 7.2 W (system), `PDTR` 13.2 W
  (adapter in), `PPBR` 1.6 W (battery), `TB0T` 34.7 °C. [D]
- Signing: one "Apple Development" certificate, no Developer ID
  certificate. [D]

## Write test results (2026-11-18, approved by the user)

Tools: `probes/powerui_set.m`, `probes/chie_test.c`. All settings restored
(limit 80%, `CHIE` 00, adapter connected).

1. Native limit, no root: `setMCLLimit:85 error:` returned ok;
   `getMCLLimitWithError:` and `pmset -g battlimit` showed 85; restored to
   80 the same way. [D]
2. Native limit below 80%, root: wrote `MCLFeatureState` = 1 and
   `mclLimitValue` = 75 to root's `com.apple.smartcharging.topoffprotection`
   domain and posted `com.apple.smartcharging.defaultschanged`. Within 3 s
   the client and `pmset -g battlimit` showed 75. Restored to 80. [D]
   Not tested: that the battery actually stops or drains at 75 over time.
3. Adapter cut, root: writing `CHIE` = 08 succeeded; within 2 s adapter
   input fell from about 6–8 W to 0.5 W and the Mac reported "Battery
   Power". Writing 00 restored AC within 2 s. [D]
   Not tested: behavior across sleep, reboot, or with the lid closed.

Decision changes:
- Decisions 1 and 2 are confirmed on this Mac.
- Decision 3 is reopened: the user has a paid Apple Developer membership,
  so a Developer ID certificate, `SMAppService.daemon`, and notarization
  are available. Only an "Apple Development" certificate is installed
  today; a Developer ID Application certificate must be created first.
- Official limits (80–100 in steps of 5) can be set without root. Root is
  needed only for targets below 80% and for adapter cut.

## Helper results (2026-11-18, approved by the user)

- `SMAppService.daemon` registers with an "Apple Development" certificate;
  Developer ID is not needed on the developer's own Mac. Before the first
  `register()`, `status` is `.notFound`, not `.notRegistered`. [D]
- A limit of 70% written by the root helper is reported by the PowerUI
  client at once, but `pmset -g battlimit` showed it after 90 s in one run
  and 26 s in another (battery at 62–65%, charging). A limit of 80% set
  with `setMCLLimit:` shows in pmset immediately. [D]
- The helper's caller check (`setConnectionCodeSigningRequirement`) refused
  an unsigned program and one signed ad hoc with Hachibu's identifier
  (XPC error 4097). [D]

## Hold test at 60% (2026-11-18, asked for by the user)

Raw readings: `hold-test-60.log`. Charger attached the whole time; limit
set through the helper with `Hachibu --set-limit 60`.

- 18:30, battery at 80%: `pmset -g battlimit` reported 60 within the same
  minute. [D]
- 18:32 to 19:06: the Mac ran on the battery while plugged in, at 1.0 to
  1.7 A out of the battery, and the level fell from 80% to 60% in 36
  minutes. macOS drains to a limit below the current level by itself
  (`chargeSocLimitDrain = 1`); the helper's adapter cut was not used. [D]
- 19:08 to 19:14: steady at 60% with 0 mA, charger attached, not
  charging. The drain stops at the limit. [D]
- 19:15: limit set back to 80%; pmset showed 80 at once and charging
  resumed within a minute (1.9 A in). [D]
- Stopped after 45 minutes instead of 60. Not tested: a hold of several
  hours, sleep, lid closed, reboot.

## Sleep, lid, and restart at a 76% limit (2026-11-18, asked for by the user)

Raw readings: `sleep-test.log`. Charger attached; limit set through the
helper. Short runs, at the user's request.

- Sleep from the Apple menu, 3.5 minutes: level 78% before and after
  (still draining toward 76), pmset 76, not charging. The drain toward
  the limit did not continue during sleep. [D]
- Lid closed, 8.6 minutes: 76% before and after, 0 mA. [D]
- Restart: pmset reported 76 two minutes after boot, the helper answered,
  and Hachibu's saved limit was 76. The level read 74% after the restart,
  charged at up to 1.6 A, and stopped at 76% within four minutes. [D]
- Not tested: hours asleep, a night with the lid closed, a cold boot
  after a shutdown, a macOS update.

## Adapter cut with a limit below the level (2026-11-18)

Found while building Discharge (S-021), through `Hachibu --try discharge 12`
and the helper.

- Limit 70% (helper), level 80%, charger attached. The helper wrote `CHIE`
  = 08: within 4 s `ExternalConnected` and `AppleRawExternalConnected` were
  No, `PDTR` 0.5 W, the Mac on "Battery Power". `AdapterDetails` stayed
  filled in, and SMC `AC-W` read 1, so a charger that is cut can still be
  told from one that is unplugged. [D]
- After 12 s the helper wrote `CHIE` = 00 and the key read 00. The Mac
  stayed on "Battery Power" (`pmset -g ac`: "No adapter attached", `PDTR`
  0.49 W) for two minutes. `setMCLLimit:80` was accepted by the PowerUI
  client, but `pmset -g battlimit` kept 70. [D]
- Turning the limit off (`disableMCL:`) brought AC power back within
  seconds; setting 80% again then showed 80 in pmset at once. [D]
- Control, with no cut: limit 70% at level 80% drains at about 0.4 A while
  the Mac stays on "AC Power" with `ExternalConnected` Yes, and a change to
  80% shows in pmset at once. [D]
- Reading: macOS drains to a limit below the level by itself. Cutting the
  adapter on top of that leaves a state that releasing the cut does not
  undo. Seen once; not understood. The first cut test (limit 80% at about
  80%, nothing to drain) restored within 2 s.
- Decision needed: Discharge by adapter cut is not shipped. macOS's own
  drain already gives "run on the battery, plugged in, down to the limit".

## Is calibration worth building? (2026-11-18, web research by a Sonnet subagent)

Marks here: [V] the page was read through a fetch tool that summarises
pages, so not the raw text; [U] uncertain or from a search summary only.
Nothing below was measured on this Mac.

- AlDente claims the battery management system "loses track" when the
  battery sits at mid or low charge for long: shutdowns at 40–50%, erratic
  reported capacity, fast percentage drops, all temporary and gone after a
  cycle. Its Calibration Mode charges to full, discharges to 10%, charges
  to full, restores the limit, and disables sleep. It recommends monthly,
  or every two weeks around 50%. It cites no evidence; the FAQ links
  Battery University.
  [V](https://apphousekitchen.com/feature-explanation-calibration-mode-2/)
  [V](https://apphousekitchen.com/faq/)
- Apple: with Optimized Charging or a Charge Limit the Mac "will
  occasionally charge to 100% to maintain accurate battery
  state-of-charge estimates". No frequency, no deep discharge. Apple also
  says charging resumes when the level drops by more than 5% while
  plugged in. [V](https://support.apple.com/102338)
- Battery University, generic lithium-ion, not Apple: the gauge drifts
  from the cells after many partial discharges; calibrate every three
  months or 40 partial cycles; not needed if the device deep-discharges
  by itself; impedance-tracking packs may need less. Calibration corrects
  the readout, not the capacity.
  [V](https://batteryuniversity.com/article/bu-603-how-to-calibrate-a-smart-battery)
- Texas Instruments Impedance Track gauges update capacity from two
  rested voltage readings far apart in charge level. That a narrow charge
  window for weeks degrades the reading is an inference from this, not a
  sourced finding, and whether Apple's pack works this way was not
  confirmed. [U]
- batt has an experimental calibration: discharge below 15%, charge to
  100%, hold two hours, discharge back to the limit. No rationale given.
  [V](https://github.com/charlie0129/batt/blob/master/docs/usage.md)
- User reports: anecdotes only. No verified case on Apple silicon of a
  shutdown at a non-zero percentage fixed by a full cycle. BatFi and
  Battery Toolkit were not checked.
- Reading: calibration can plausibly fix the reading (percentage and
  reported capacity). No source claims it improves the battery, and each
  run costs a full cycle, a deep discharge, and hours at 100%. macOS's
  own full charge gives the gauge a top reference but no deep discharge.
- Decision taken: keep S-042 as an optional, manual feature, worded as
  "fixes the reading, not the battery", with no schedule and no reminder.

## How fast macOS stops charging when asked (2026-11-19, for S-040)

Raw readings: `heat-probe.log`. The battery was charging under a 90%
limit at 1.1 to 1.6 A; Hachibu then asked for a lower limit through the
helper. The menu bar copy was quit during the runs.

| Asked for | At level | pmset reported it after | Current seen stopped after |
| --- | --- | --- | --- |
| the level itself, 81% | 81% | 100 s | 160 s (level had risen to 82%, so macOS then drained 1%) |
| the level itself, 83% | 83% | 60 s | 120 s |
| one under the level, 83% | 84% | 119 s | not within 120 s; stopped by 3 minutes |

- While the battery is charging, macOS applies a new limit one to two
  minutes after it accepts it, whether the limit is the level itself or
  below it. The charging service reports the new limit at once. [D]
- The battery current in the registry changes in steps about a minute
  apart, so "current stopped" may be up to a minute late. [D]
- When the battery is not charging, a new limit applies at once: 15% at
  83% and 80% at 85% both showed in pmset within the second. [D]
- So pausing a charge by asking for the level takes one to three minutes
  to show. S-040 set a bar of under two minutes; this does not meet it.

## A limit of 15% (2026-11-19, for S-042)

- `Hachibu --probe-limit 15` with the battery at 83%, not charging: the
  charging service and pmset both reported 15% at once. [D]
- `Hachibu --try calibration 20` at 85%: the status read "Calibrating",
  macOS held a 15% limit and went on draining (about 0.5 to 1.5 A out),
  and stopping it brought 80% back at once. [D]
- Not run: a whole calibration (hours).

