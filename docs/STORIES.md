# Hachibu stories

Built from `docs/BRIEF.md` and `docs/research/charge-control.md`.
Checks: `[snap]` snapshot, `[unit]` unit test, `[self]` self-test,
`[manual]` a person must try it on the Mac.

Snapshot pages use fake battery readings, never the real battery. Pages:
`popover`, `popover-warning`, `popover-topup`, `popover-discharge`,
`settings-general`, `settings-charging`, `settings-helper`, `history`,
`calibration`.

Status words (one name each, see `docs/GLOSSARY.md` once it exists):
Charging, Holding at limit, On battery, Topping up, Discharging, Sailing,
Paused for heat, Full charge by macOS, Limit not holding.

## M1 Core loop: a limit you can trust (no helper)

Built 2026-11-18. Checked by unit tests, the self-test on the real
battery, fixture snapshots, and one real limit change (80 to 85 and back,
confirmed with `pmset -g battlimit`). Still to try by hand: clicking
through the popover, the keyboard, the notification, and a restart.
Changes from the stories as written:
- Health shows the figure macOS reports (System Settings), read hourly,
  so the two never disagree; raw capacity over design capacity is the
  fallback.
- With no saved limit, the popover offers "Keep This Limit" to adopt the
  one macOS already holds.
- Two more statuses exist: "Fully charged" and "Not charging".
- Settings has four tabs (General, Charging, Helper, About), not three.

Ends with: a menu bar app that sets an 80–100% limit, shows the truth
about it, and remembers it. No admin rights needed.

### S-001 See the battery in the menu bar
As the user, I see a battery icon with the percentage in the menu bar,
and no Dock icon or main window.
Screens: popover
Acceptance:
- [manual] The menu bar shows a battery icon and the same percentage as
  `pmset -g batt`, updated within 30 seconds of a change.
- [manual] The app has no Dock icon and opens no window at launch.
- [unit] The icon name is chosen from percent and state (charging, on
  battery, holding).
- [self] The template's sample list (Item, All Items, Starred) is gone.
UX:
- Flow: launch -> battery icon and percentage appear in the menu bar -> click opens the popover -> click again or Escape closes it
- Surface: menu bar item (a place people come back to, with no window of its own)
- States: reading unavailable shows the icon with "–"; warning adds an exclamation mark to the icon, never color alone
- Words: no text beyond the percentage, for example "80%"
- Access: VoiceOver "Hachibu, battery 80 percent, Holding at limit"; the item opens with VoiceOver's menu bar navigation
Status: done

### S-002 Open the popover and read the status
As the user, I click the menu bar icon and see the percentage and one
status line that says what the battery is doing.
Screens: popover
Depends: S-001
Acceptance:
- [snap] The popover shows the percentage, a status line, and health,
  cycles, and temperature rows.
- [unit] Status is derived from a reading: Charging (current into the
  battery), Holding at limit (plugged in, no current, at or near the
  limit), On battery (not plugged in).
- [unit] Health is `AppleRawMaxCapacity / DesignCapacity`, read from the
  `BatteryData` dictionary, rounded to a whole percent.
- [self] A real reading from this Mac parses without missing fields.
UX:
- Flow: click the menu bar item -> popover opens with the percentage and status on top -> Escape or a click outside closes it
- Surface: popover (a few related choices tied to one control)
- States: no reading "Battery information unavailable" with the reason; Mac without a battery "This Mac has no battery"
- Words: status terms from the glossary only; rows "Battery health 82%", "Cycles 274", "Temperature 34.7 °C"
- Access: nothing has focus on open; Tab reaches the slider, then buttons, then footer; VoiceOver reads the percentage and status as one element
Status: done

### S-003 See whether current is really flowing
As the user, I see the measured power next to the status, so the status
line can never claim something the numbers contradict.
Screens: popover
Depends: S-002
Acceptance:
- [snap] The status line shows a dot and watts, for example
  "Not charging · 9.2 W in".
- [unit] Watts come from `PDTR` (charger in), `PSTR` (system), `PPBR`
  (battery); a missing key shows "–", not 0.
- [unit] "Holding at limit" is never shown while battery current is
  above the charging threshold.
- [manual] Unplugging the charger changes the line within 5 seconds.
UX:
- Flow: the status line updates itself every few seconds while the popover is open; no action needed
- Surface: inline in the popover's status line (information that needs no action)
- States: missing value shows "–"; values round to one decimal below 10 W, whole watts above
- Words: "Charging · 28 W in", "Holding at limit · 9.2 W from charger", "On battery · 7 W out"
- Access: the state is a word plus a dot, never a dot alone; VoiceOver reads "9.2 watts from charger"
Status: done

### S-004 See who set the limit
As the user, I see the current limit and whether Hachibu, System
Settings, or another app set it.
Screens: popover
Depends: S-002
Acceptance:
- [snap] The popover shows "Limit 80%" with its source underneath.
- [unit] The source is "Hachibu" when the macOS limit equals the saved
  one, otherwise "set outside Hachibu".
- [unit] With the macOS limit off, the popover shows "No limit".
- [manual] Changing the slider in System Settings > Battery shows up in
  the popover within 30 seconds, marked as set outside Hachibu.
UX:
- Flow: read the limit and its source under the slider -> if set outside Hachibu, click "Use Hachibu's Limit" to apply the saved one, or move the slider to adopt a new one
- Surface: inline under the slider (information tied to one control)
- States: "Set by Hachibu"; "Set outside Hachibu" with the button; "No limit"
- Words: "Limit 80%", "Set outside Hachibu", button "Use Hachibu's Limit"
- Access: the source line is read with the slider's value; the button is reachable with Tab
Status: done

### S-005 Set a limit from 80% to 100%
As the user, I drag the limit slider in the popover to 80, 85, 90, 95,
or 100%.
Screens: popover
Depends: S-004
Acceptance:
- [snap] The slider shows five stops and the chosen value.
- [unit] Values snap to the stops macOS reports as available.
- [manual] After choosing 85%, `pmset -g battlimit` shows 85 within 10
  seconds; choosing 100% turns the limit off.
- [manual] The popover shows "Applying…" until macOS confirms the value,
  and an error line if macOS refuses.
- [self] The chosen limit is saved and read back from a /tmp store.
UX:
- Flow: drag the slider, or focus it and press the arrow keys -> the value snaps to a stop -> "Applying…" -> the confirmed value shows; 100% means No limit
- Surface: inline slider in the popover (changes one value on something already on screen)
- States: applying "Applying…"; refused "macOS did not accept this limit. Try again." under the slider, slider returns to the confirmed value; without the helper a note "Limits below 80% need the helper." with "Set Up…"
- Words: label "Limit", stops 80 to 100, tooltip on the note button "Open Settings to install the helper"
- Access: arrow keys move one stop; VoiceOver "Limit, 85 percent, adjustable"
Status: done

### S-006 Get warned when the limit is not holding
As the user, I get a clear warning when the battery charges above my
limit, instead of a status that looks normal.
Screens: popover-warning
Depends: S-003, S-005
Acceptance:
- [snap] The popover shows a warning banner "Limit not holding" with
  the measured percent and limit.
- [unit] The warning starts when percent is more than 2 above the limit
  and current flows into the battery for 2 minutes; it clears when either
  stops.
- [unit] No warning while Topping up or Full charge by macOS is active.
- [manual] One notification is sent when the warning starts, not one
  per reading.
- [manual] The menu bar icon shows a warning mark while it lasts.
UX:
- Flow: warning starts -> banner at the top of the popover, a mark on the menu bar icon, one notification -> click the notification to open the popover -> "Apply Limit Again" retries -> banner clears when the limit holds
- Surface: inline banner in the popover (a problem shown where the status is; not an alert, since nothing is lost)
- States: holding again removes the banner without a message; retry failed keeps the banner and adds "macOS did not accept the limit."
- Words: banner "Limit not holding" / "Battery is at 86% and still charging. The limit is 80%."; button "Apply Limit Again"; notification title "Limit not holding", same body
- Access: warning icon plus words, not color alone; VoiceOver announces the banner when the popover opens
Status: done

### S-007 Keep the limit across quit and restart
As the user, I quit Hachibu or restart the Mac and my limit is still
there, and Hachibu shows it correctly when it opens again.
Screens: popover
Depends: S-005
Acceptance:
- [manual] After quitting Hachibu, `pmset -g battlimit` still shows the
  limit.
- [manual] After a restart and launch, the popover shows the same limit
  with source Hachibu.
- [unit] On launch, a saved limit that differs from the macOS limit is
  shown as "set outside Hachibu" and is not overwritten silently.
UX:
- Flow: launch -> Hachibu reads the macOS limit -> shows it with its source; it never changes the limit at launch without a click
- Surface: none of its own; shown by the limit line from S-004
- States: saved and macOS limits differ -> "Set outside Hachibu" with "Use Hachibu's Limit"
- Words: as in S-004
- Access: as in S-004
Status: done

### S-008 Quit and open Settings from the popover
As the user, I open Settings or quit Hachibu from the popover.
Screens: popover, settings-general
Depends: S-002
Acceptance:
- [snap] The popover footer has History…, Settings…, and Quit.
- [manual] Command-comma opens Settings; Command-Q quits.
- [snap] Settings opens with General, Charging, and Appearance tabs.
UX:
- Flow: popover footer -> "History…" opens the History window, "Settings…" opens Settings (Command-comma), "Quit Hachibu" quits (Command-Q)
- Surface: footer row of plain buttons in the popover; Settings and History are windows (self-contained tasks kept open beside other work)
- States: quitting during a Top Up or Discharge restores the limit and charger first, without asking
- Words: "History…", "Settings…", "Quit Hachibu"
- Access: all three reachable with Tab; shortcuts work while the popover is open
Status: done

## M2 Helper: limits below 80%

Ends with: any limit from 20 to 99%, through a helper that installs and
uninstalls cleanly.

### S-010 Install the helper
As the user, I turn on "Advanced charging control" in Settings and
approve the helper once in System Settings.
Screens: settings-helper
Acceptance:
- [snap] The Helper tab shows the state: Not installed, Needs approval,
  Running, or Failed with the reason.
- [manual] After approval the tab shows Running within 5 seconds, and
  the helper appears once in System Settings > Login Items.
- [manual] The helper refuses connections from any program not signed
  with Hachibu's Developer ID.
- [unit] Helper requests are a closed list: set limit, restore adapter,
  read status. Nothing else is accepted. ("Cut adapter" was on this list
  until 2026-11-19; it went with the Discharge story.)
- [manual] The app and helper are signed with a Developer ID
  certificate and the build is notarized.
Status: done (2026-11-18: signed with Developer ID and accepted by
Apple's notary. The helper was first tried with an Apple Development
certificate, which is also enough on the developer's own Mac.)

### S-011 Set a limit from 20% to 99%
As the user, with the helper running, I drag the slider to any whole
percent from 20 to 100.
Screens: popover, settings-charging
Depends: S-010, S-005
Acceptance:
- [snap] The slider runs from 20 to 100 when the helper is running, and
  from 80 to 100 with a note when it is not.
- [manual] After choosing 70%, `pmset -g battlimit` shows 70 within two
  minutes, and the popover says "Applying…" until it does. (Was "within
  10 seconds"; macOS took 25 to 90 seconds on this Mac.)
- [manual] Left plugged in for an hour above the limit, the battery
  does not charge. (Tried for 45 minutes at 60%: it drained to 60% and
  held there.)
- [unit] The helper rejects values outside 20–100.
Status: done

### S-012 Remove the helper
As the user, I click "Remove helper" and everything it installed is
gone, with charging back to normal.
Screens: settings-helper
Depends: S-010
Acceptance:
- [manual] After removal, no Hachibu entry remains in Login Items and
  no Hachibu helper process runs.
- [manual] Removal restores the adapter and sets the limit to the
  nearest value macOS allows without the helper (80% or above).
- [snap] The tab asks for confirmation and says what will change.
Status: done

### S-013 See the helper's health
As the user, I see in the popover when the helper is needed but not
running, with a button to fix it.
Screens: popover-warning
Depends: S-010
Acceptance:
- [snap] A banner "Helper not running" with a "Fix…" button shows when
  the saved limit is below 80% and the helper is missing.
- [unit] The banner does not show when the limit is 80% or above.
Status: done

## M3 Overrides: top up, discharge, sailing

### S-020 Top up to 100% once
As the user, I click "Top up" before travel; the battery charges to
100% and my limit returns afterwards.
Screens: popover-topup
Depends: S-005
Acceptance:
- [snap] While active, the status is "Topping up" and the button reads
  "Stop".
- [unit] Top up ends when the charger is unplugged or when I click Stop;
  the saved limit is then applied again. At 100% it stays on and keeps
  the battery full. (Changed 2026-11-19, was "ends at 100%": with the
  limit back, macOS drains to it while still plugged in, so a Top Up left
  on the charger overnight was gone by morning.)
- [manual] After unplugging and plugging back in, the limit is back.
- [manual] Quitting Hachibu during a top up restores the limit first.
Status: done (2026-11-18. Tried for real with `Hachibu --try topup 20`:
the limit went off and came back to 80%. The user then tried the
button and Stop, unplugging during a Top Up, and Quit during a Top Up,
and reported that all passed.)

### S-021 Discharge to the limit while plugged in
As the user, I click "Discharge" and the Mac runs on battery, still
plugged in, until it reaches the limit.
Screens: popover-discharge
Depends: S-010
Acceptance:
- [snap] While active, the status is "Discharging" with watts out and
  the button reads "Stop".
- [manual] Within 5 seconds the Mac reports battery power; at the limit
  the adapter is restored.
- [unit] Discharge refuses to start at or below the limit, and stops at
  the limit, at 20%, on Stop, or when the charger is unplugged.
- [manual] If the helper stops for any reason, the adapter is restored.
Status: dropped (2026-11-18, the user's decision).
- On this Mac macOS already does this by itself: with the limit below the
  level it drains the battery to the limit while staying on AC power.
- The one real try of the adapter cut (limit 70%, level 80%, cut for 12
  seconds, then released) left the Mac on battery for two minutes, until
  the limit was turned off. See `docs/research/charge-control.md`,
  "Adapter cut with a limit below the level".
- The Discharge code was removed, and since 2026-11-19 the helper no
  longer accepts "cut adapter". It can only reconnect the charger.

### S-022 Sail between two levels
As the user, I set a sailing range in Settings, and the battery drifts
down that many percent before it charges back to the limit.
Screens: settings-charging, popover
Depends: S-021
Acceptance:
- [snap] Settings > Charging has a "Sailing range" control from 0 (off)
  to 10 percent; the popover status reads "Sailing" while drifting.
- [unit] With limit 80 and range 5, charging resumes at 75 and stops at
  80.
- [unit] Sailing pauses during Top up and Calibration.
Status: done (2026-11-18). Built without the adapter cut, so it does not
need S-021: inside the range Hachibu asks macOS to hold the level the
battery is at, and at the bottom of the range it asks for the limit
again. Tried for real with `Hachibu --try sailing 50` (limit 85%, level
80%, range 10): macOS held 80%, charging stopped, the status read
"Sailing", and turning sailing off brought 85% back. Needs the helper.
The user tried the slider with the helper running and reported that it
passed. Not tried: a full drift down and recharge over a day.

### S-023 Sleep safely during discharge or sailing
As the user, I close the lid during discharge or sailing; the charger
is reconnected before sleep and the mode resumes on wake.
Screens: popover
Depends: S-021
Acceptance:
- [manual] Closing the lid mid-discharge: on wake, the log shows the
  adapter was restored before sleep and cut again after wake.
- [manual] The Mac is never kept awake by Hachibu.
- [unit] The sleep handler restores the adapter in every active mode.
Status: dropped with S-021 (2026-11-18): Hachibu never cuts the adapter, so there is nothing to protect.

### S-024 Recover after a crash or forced quit
As the user, I never end up stuck on battery because Hachibu or its
helper stopped.
Screens: popover
Depends: S-021
Acceptance:
- [manual] Force-quitting the app during discharge restores the adapter
  within 30 seconds.
- [manual] Killing the helper restores the adapter when it relaunches.
- [unit] The helper restores the adapter when its client has been
  silent for 30 seconds.
Status: dropped with S-021 (2026-11-18): Hachibu never cuts the adapter, so there is nothing to protect.

## M4 Details: power flow and history

### S-030 See power flow
As the user, I see a card showing watts from the charger, into the Mac,
and into or out of the battery.
Screens: popover
Depends: S-003
Acceptance:
- [snap] The card shows three labelled values and arrows whose
  direction matches the sign of battery power.
- [unit] On battery, the charger value reads 0 W and the battery arrow
  points to the Mac.
Status: done (2026-11-18. The card was built in M1; the rule behind it is now `PowerFlow` with a unit test.)

### S-031 Record battery samples
As the user, Hachibu records the battery level, power, temperature, and
state once a minute while it runs.
Screens: history
Acceptance:
- [self] Adding samples to a /tmp store and reading them back returns
  them in time order.
- [unit] Samples older than 90 days are thinned to one per hour.
- [manual] After a day of running, CPU use stays under 1% and the
  database under 5 MB.
Status: done (2026-11-18. Kept in two small files of fixed-size records
(`HistoryStore`), 16 bytes a sample, so 90 days of minutes is about 2 MB.
Seen recording on this Mac: two samples a minute apart, with CPU at 0%.
Not checked: a whole day of running.)

### S-032 See the last 24 hours in the popover
As the user, I see a small chart of battery level over the last 24
hours, with the limit drawn as a line.
Screens: popover
Depends: S-031
Acceptance:
- [snap] The chart card shows the level line and the limit line.
- [snap] With under an hour of data, the card says "Collecting data".
Status: done (2026-11-18. The chart begins at the first sample, so a first day is not padded with an invented line.)

### S-033 Browse history
As the user, I open the History window and view level, temperature, and
power over a day, a week, or a month.
Screens: history
Depends: S-031
Acceptance:
- [snap] The window has a range picker (Day, Week, Month) and three
  charts.
- [snap] Hovering a chart shows the value and time at that point.
- [snap] With no data, the window shows an empty state.
Status: done (2026-11-18. The window reads what was recorded; the
`history-recorded` snapshot writes made-up samples to the test store and
reads them back. Hover was not checked: snapshots cannot move the
pointer.)

### S-034 Track battery health over time
As the user, I see how maximum capacity and cycle count change over
months.
Screens: history
Depends: S-031
Acceptance:
- [unit] One health snapshot is saved per day, at most.
- [snap] The History window has a Health chart with capacity percent
  and cycle count.
Status: done (2026-11-18. Saved once macOS has given its own health figure,
so the chart matches System Settings. The chart needs days to show a
change.)

## M5 Protection: heat, calibration, full charge

### S-040 Pause charging when the battery is hot
As the user, I set a temperature in Settings; above it, charging pauses
until the battery cools.
Screens: settings-charging, popover
Depends: S-010, S-022
How (rewritten 2026-11-18, no adapter cut): the same move as sailing.
While the battery is hot and charging, Hachibu asks macOS to hold the
level the battery is at; when it has cooled, Hachibu asks for the user's
limit again. Needs the helper, because the level is rarely a limit macOS
offers by itself.
Known from real runs: holding 80% (a limit macOS offers) stopped the
current within about 10 seconds. A level in between goes through the
helper, which macOS took 25 to 90 seconds to enforce. So the pause is not
instant, and the story must say so on screen.
Acceptance:
- [manual] First, a probe: with the battery charging at a level macOS
  does not offer (for example 63%), ask for that level and time how long
  until the current stops. Build the story only if it is under two
  minutes; write the measured time into the Settings row.
- [snap] Settings > Charging has a "Heat protection" toggle and a
  temperature from 30 to 45 °C, disabled with the reason when the helper
  is not running; the status reads "Paused for heat".
- [unit] Charging pauses above the threshold and resumes 2 °C below it.
- [unit] The level asked for is never below the battery's level, so a
  pause never makes macOS drain the battery (draining makes heat). If the
  level rose while macOS was slow to act, the hold moves up to it.
- [unit] A pause also holds during a Top Up, and the Top Up continues
  when the battery has cooled.
- [unit] Heat protection never pauses a full charge by macOS; it cannot.
Status: done (2026-11-19). The user chose to build it although a pause
takes longer than the two minutes first asked for; the Settings row says
how long it takes.
- Default 40 °C, range 36 to 43 °C, from the research in
  `docs/research/charge-control.md`. The pause begins only after three
  minutes above the threshold, and holds one percent above the battery's
  level so macOS never drains it.
- Real run (`docs/research/heat-run.log`, threshold lowered to one degree
  under the battery's temperature while charging under a 90% limit): the
  pause began at 180 seconds and asked for 83% with the battery at 82%;
  macOS enforced it about two minutes later; charging was seen stopped at
  345 seconds, with the battery at 83% and no drain. Turning it off put
  the user's limit back.
- Not seen: a pause caused by real heat, the resume 2 °C below, and a
  pause during a Top Up or a calibration (unit tests only).

### S-041 Know when macOS is doing a full charge
As the user, I am told when macOS charges past my limit on its own, and
why, so I do not mistake it for a failure.
Screens: popover
Depends: S-006
Acceptance:
- [snap] The status reads "Full charge by macOS" with a one-line reason.
- [unit] The state follows
  `com.apple.system.powersources.chargingtofulloverride`.
- [manual] One notification when it starts; the "Limit not holding"
  warning stays off.
Status: done (2026-11-19. The status and its reason are in the
`popover-fullcharge` snapshot; the notice is sent once when a full charge
starts, not for one already under way at launch. Not seen for real: macOS
does this every few weeks, so the notification itself is unconfirmed.)

### S-042 Calibrate the battery
As the user, when the percentage or the health figure looks wrong, I
start a calibration: macOS drains the battery to 15%, charges it to 100%,
rests there for two hours, then my limit returns.
Screens: calibration
Depends: S-010, S-020
Why (researched 2026-11-18, `docs/research/charge-control.md`, "Is
calibration worth building?"): it can correct the reading, not the
battery. AlDente and Battery University recommend it for batteries kept
in a narrow range; Apple only says macOS charges to 100% now and then to
keep its estimates accurate, which gives no deep discharge. Evidence of
real trouble on Apple silicon is anecdotal. So: manual, optional, no
schedule, no reminder, and the sheet says what it costs.
How (no adapter cut): limits in a row. A limit of 15% until the battery
is there (macOS drains to a limit below the level by itself, staying on
AC power); no limit until 100%; two hours at 100%; then the user's limit,
and macOS drains back to it. This is batt's order and batt's depth.
Why 15% and not 10% (AlDente's): from 100% it is already the 85% depth
the gauge notes mention; no source shows 10% reads better; 10% is where
macOS starts its low battery warnings; and if the charger is pulled
mid-run, 15% leaves some room. The helper accepts 20 to 100 today, so
this story widens it to 15 to 100 (a new helper version: remove and
install once). The slider stays at 20.
Known from real runs: macOS drained 80% to 60% in 36 minutes awake, so
80% to 15% should take about two hours. In 3.5 minutes of sleep the level
did not fall, so the drain seems to stop while the Mac sleeps.
Acceptance:
- [snap] A sheet shows the steps, the current step, the level, and a
  Cancel button.
- [snap] Before starting, the sheet says: it corrects the reading and
  does not improve the battery; it uses one full cycle; it takes several
  hours; the charger must stay connected; the drain waits while the Mac
  sleeps. Hachibu does not keep the Mac awake.
- [manual] First, a check: ask for 15% through the helper and confirm
  macOS reports and enforces it. Only 75%, 70%, and 60% have been tried.
- [unit] The helper accepts 15 to 100 and nothing lower; the slider
  still stops at 20.
- [unit] Steps advance at 15%, at 100%, and after two hours at 100%; then
  the user's limit is asked for again.
- [unit] Cancel restores the user's limit at once. Unplugging pauses the
  step and it continues when the charger is back.
- [unit] Sailing and heat protection are paused while it runs (heat
  protection: decide when S-040 is built).
- [manual] A notification is sent when calibration finishes.
- [manual] One full run on this Mac, with the time of each step and the
  health figure before and after written into the research file.
Status: done (2026-11-19), except the full run. macOS took and enforced
15% at once. A real 20-second run showed "Calibrating" with a 15% limit
and gave 80% back on Stop. It is started from Settings > Charging;
the popover shows the step and a Stop button. If Hachibu stops during a
calibration or a Top Up, the next launch puts the user's limit back.
Still to do by hand: one whole calibration, with the time of each step
and the health figure before and after.

## M6 System and polish

### S-050 Launch at login
As the user, I turn on "Open at login" in Settings.
Screens: settings-general
Acceptance:
- [snap] General has an "Open at login" toggle.
- [manual] After a restart, Hachibu is in the menu bar without my doing
  anything.
Status: done (the user confirmed it on 2026-11-19)

### S-051 Choose what the menu bar shows
As the user, I choose whether the menu bar item shows the percentage.
Screens: settings-general
Depends: S-001
Acceptance:
- [snap] General has a "Show percentage" toggle.
- [manual] Turning it off leaves only the icon.
Status: done (the switch and the menu bar were built in M1; the rule has
a unit test. Not confirmed by eye on the real menu bar.)

### S-052 Choose which notifications I get
As the user, I turn each notification on or off: limit not holding,
full charge by macOS, top up finished, calibration finished.
Screens: settings-general
Acceptance:
- [snap] General lists the four toggles.
- [unit] A disabled kind is never sent.
Status: done (`Notice` in HachibuKit decides it. "Top Up finished" is
sent when the battery is seen at 100% during a Top Up; no real
notification of that kind has been seen yet.)

### S-053 App icon
As the user, I see a Hachibu icon in Finder and Settings.
Screens: none (icon review sheet)
Acceptance:
- [manual] `tools/icon_review.sh` shows the icon in every look.
Status: done (reviewed 2026-11-19: Default, Dark, Tinted, Clear, and at
32 and 16 pt)

### S-054 Publish as open source
As a visitor, I can read what Hachibu does, how it controls charging,
its limits, and how to build it.
Screens: none
Acceptance:
- [manual] `README.md` covers: what it does, supported Macs and macOS,
  the two control methods and their limits, build steps, uninstall, and
  credit to batt (charlie0129/batt).
- [manual] A license file exists.
- [manual] The repo has no personal names, emails, or team IDs in
  tracked files.
Status: in progress. `README.md` is written (2026-11-19). Tracked files
were searched for names, emails, home paths, and the team ID: none
found. Open, both the user's call: the license, and the commit history,
whose author line carries a name and an email address.

## Later

- Shortcuts actions: Set Limit, Get State, Top Up.
- Global hotkeys for Top up and Discharge.
- A choice of menu bar icon styles.
- A command-line tool.

## Dropped

- Schedules and location rules: one user, one desk.
- Per-app power use, quitting or throttling apps: out of scope for a
  charge controller.
- Charging-light control: the MacBook Air M1 has no MagSafe.
- Intel Macs and macOS before 27: one target Mac.
- Holding the limit while shut down: not possible on Apple silicon.
- Accounts, licensing, upgrade prompts, analytics: personal and open
  source.
- Blocking the macOS full charge with adapter cut: the user chose
  accept and notify.
