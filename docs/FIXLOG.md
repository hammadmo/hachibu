# Fix log

One entry per bug: symptom, cause, fix, and a rule.

## 2026-11-18 A command-line run never quit

Symptom: `Hachibu --set-limit 83` printed nothing and stayed running for
eleven minutes.
Cause: the quit handler answers "later" and starts a task to put the
user's limit back. The command-line run called `NSApp.terminate` from
inside a task on the main actor, so that second task could never start.
Clicking Quit in the app does not start from a task and worked.
Fix: command-line runs put the limit back first, then quit
(`Launch.quit`).
Rule: never call `NSApp.terminate` from a task while the quit handler may
answer "later"; do the cleanup before asking to quit.

## 2026-11-18 Two copies of Hachibu pulled the limit against each other

Symptom: a limit of 83% set from the command line showed 80% in pmset.
Cause: sailing was on in the menu bar copy, which held the battery at its
level (80%). The command-line copy ran its own sailing as well and, on
quitting, put 83% back.
Fix: a one-shot command-line run does not run Top Up or sailing
(`runsModes`).
Rule: only the copy in the menu bar decides modes; a second copy sets
what it was asked and nothing else.

## 2026-11-18 A failed build installed the previous program

Symptom: `./build.sh` printed compile errors and then "installed".
Cause: the script guessed failure from file dates ("a source newer than
the program"). With two programs, one rebuilt and one not, the guess said
everything was fine.
Fix: the script uses the exit code of `swift build`.
Rule: decide success from the tool's exit code, never from file dates or
from searching its output.

## 2026-11-19 The snapshot comparison said SAME for pictures of different sizes

Symptom: `tools/compare-shots.sh` printed "SAME (48 pages)" against
snapshots taken before the popover gained a chart.
Cause: ImageMagick cannot compare two sizes and prints an error; the
script read the error text as the number 0.
Fix: the script uses the exit code and requires a number.
Rule: a check that cannot run has failed; never read a tool's error text
as a result.

## 2026-11-19 History drew lines for time that was not recorded

Symptom (found in review, before any user saw it): a night asleep drew
as a flat line and a cliff; a temperature first measured at noon was
drawn from the morning; the limit line showed today's limit for the
whole week; health points were spread evenly, not where they were
measured.
Cause: the series builder filled every chart point, carrying values
across gaps, to keep the charts simple.
Fix: a point with nothing measured is not a number, and the charts break
the line there. The limit line is drawn only when the limit did not
change. Health is placed by its time.
Rule: a chart point is either something measured or a gap; never fill.

## 2026-11-19 A mode could lose or overwrite the limit (found in review of M3)

Symptoms, all found by reading the code before a user met them:
- A limit set in System Settings during sailing or a Top Up was shown
  wrongly and then written over.
- A limit of the user's a little under the saved one was taken at launch
  for Hachibu's own sailing hold, and changed without a click.
- A Top Up that reached 100% on the charger gave the limit back, and
  macOS drained the battery to it.
- When putting the user's limit back failed, Hachibu forgot the limit and
  took what macOS held (100, or a sailing level) for the user's.
- A reading that flickered by 1% made sailing ask the helper for a new
  level each time.
Cause: "a mode has asked macOS for another limit" was two loose
variables, cleared at the moment the limit was asked back, not when macOS
confirmed it.
Fix: one state, `LimitOverride` (none, holding, restoring), with its rules
and tests in `HachibuKit`. The user's limit is remembered until macOS
confirms it, asked again every minute if it does not, and dropped only
for the user's own request or a change made outside Hachibu. A hold is
recognised at launch only if it is the exact level Hachibu wrote down.
Sailing moves its hold in steps of two and not at all for "no limit".
Rules:
- What macOS holds is the user's limit only when no mode has asked for
  something else and been confirmed back.
- Never adopt state at launch by guessing from values; write down what
  you did and compare.
- If the system does it for you (macOS drains to a lower limit), do not
  hand it the chance at the wrong moment.

## 2026-11-19 A commit went in with the grid lint failing

Symptom: the menu bar glyph was committed while `tools/grid-lint.sh`
printed FAIL.
Cause: the checks were chained as `tools/grid-lint.sh | tail -1 && ...`.
A pipe reports the exit code of its last command, so `tail` hid the
failure. The same shape as the earlier `;` mistake.
Fix: the lint lines got their marked exceptions, and the commit was
amended after every check passed.
Rule: never pipe a check into `tail`, `grep`, or `head` in front of `&&`.
Run it bare, or use `set -o pipefail`.

## 2026-11-19 A calibration could leave a 15% limit behind (found in review of M5)

Symptoms, found by reading the code before a user met them:
- The note of what a mode had asked macOS for was erased when the user's
  limit was asked back, not when macOS confirmed it. A failed restore
  followed by a crash left 15% (or no limit) with nothing to recover it.
- The launch restore put back the saved limit, not the limit the mode
  had replaced, and did nothing when no limit had been saved.
- A calibration could wait forever for exactly 100% or exactly 15%.
- "Your limit is back" was announced before macOS had confirmed it, and
  the launch notice "is being put back" never went away.
- A limit the user set during a mode, if it failed, left the mode's
  limit in place.
Fix: what was asked and the user's limit are both written down
(`Preferences.modeAsk`, `modeUser`) and erased only when the user's limit
is confirmed. One percent short of a step's target counts after half an
hour, and a step ends the calibration after twelve hours. Rest counts
only time on the charger. The notices wait for the confirmation. Proved
on this Mac: the app was killed mid-calibration with 15% in place, and
the next launch put 80% back.
Rules:
- Erase the record of an intervention when the system confirms it is
  undone, never when the undo is merely asked for.
- Any step that waits for the system to reach a value needs a way out:
  a near-miss rule and a time limit.
- Do not announce that something is back until it is measured back.

## 2026-11-19 Snapshots depended on where the mouse was

Symptom: after a refactor that changes nothing on screen, 15 popover
snapshots differed from the ones taken before it.
Cause: in the earlier run the pointer happened to rest over the Top Up
button, which was drawn in its hover state. The comparison also counted
see-through corner pixels, whose hidden colors change between captures.
Fix: in a snapshot run the kit's parts ignore the pointer
(`Snapshot.isRunning`), and the comparison flattens transparency and
masks the window's corners and title-bar buttons.
Rule: a picture used as proof must not depend on anything outside the
program: the pointer, the focused window, hidden pixels.

## 2026-11-19 A sailing hold could stay as the limit after a crash

Symptom: found by an independent review, not seen on the Mac. Sailing
holds 72 under a limit of 80; sailing is switched off and Hachibu stops
before macOS confirms 80. The next launch left 72 in place as "Set
outside Hachibu".
Cause: the launch treated a sailing note as "take it up or forget it".
With sailing off it could not take it up, so it erased the note. Every
other mode's note meant "put the limit back".
Fix: a sailing hold that is still exactly in place and cannot be taken
up is put back like a Top Up's limit (`ModeCoordinator.launched`).
Rule: a limit a mode asked for has two ways out at launch, carry on or
put back. Forgetting the note is only for a limit that is no longer the
one Hachibu asked for.

## 2026-11-19 The Settings window opened squeezed

Symptom: the first snapshot of a run (General, light) was 56 pt shorter
than the dark one of the same page. The real window did the same: it
opened at 589 pt where General needs 645, and Charging at 662 where it
needs 690. Rows lost their padding and the wave band was cut.
Cause: the window took its first height from a layout pass in which the
tab could still be compressed, and never grew until something else
changed (the dark snapshot, a tab switch).
Fix: the tab's content keeps its full height
(`.fixedSize(horizontal: false, vertical: true)` in `SettingsView`).
Rule: when the light and dark snapshot of one page differ in size, the
layout is wrong, not the snapshot. Compare their sizes, not only each
page with its own baseline.

## 2026-11-19 The self-test failed on battery

Symptom: `tools/selftest.sh` failed "power management enforces the limit
macOS reports" with nothing wrong. The Mac was unplugged.
Cause: on battery macOS withdraws the limit from power management, and
`pmset -g battlimit` prints "No battery level limits set". The check
compared that with the limit macOS still reports (80).
Fix: the check runs only while the charger is connected.
Rule: a check that reads the real Mac must say which state of the Mac it
holds in (charger connected, helper running), and skip the others.

## 2026-11-19 A limit below 80% set on battery waited four minutes and was called "Set outside Hachibu"

Symptom: on battery, `Hachibu --set-limit 70` took 4 minutes 11 seconds
and ended with "limit 70%, Set outside Hachibu. macOS accepted this
limit but is not enforcing it yet." The slider did the same. A Top Up
that ended by unplugging, with a helper limit to put back, would have
asked again every minute for as long as the Mac stayed on battery.
Cause: a helper limit counted as held only once `pmset -g battlimit`
showed it. On battery macOS withdraws the limit from power management
and pmset shows none, so the wait could never end well.
Fix: on battery the wait is skipped (`LimitSystem.chargerConnected`).
The limit is held once macOS reports it, as for a limit macOS offers
itself. Unplugging during the wait ends it the same way.
Rule: before waiting for a signal, ask in which states of the Mac that
signal exists at all (charger connected, awake, helper running), and do
not wait in the others.

## 2026-11-20 A built app carried the name of the Mac's user

Symptom: found by an independent review. Both programs in the built app,
and the zip published as release 0.1, contained the folder they were
built in, which is inside the builder's home folder.
Cause: the linker leaves a note for debuggers saying where each object
file is. An earlier check with `strings` had reported the app clean; it
did not look where those notes are.
Fix: `build.sh` strips those notes from both programs (`strip -S`) and
then refuses to install a build in which `grep -a "$HOME"` still finds
anything. It also puts the app together in a folder of its own and moves
it into place only when every signature has worked.
Rule: "nothing personal in the build" is a check the build runs on the
finished file with `grep -a`, not something looked at once by hand.

## 2026-11-20 The menu bar item said only "Hachibu", and a press through accessibility opened nothing

Symptom: assistive apps were told the menu bar item is called "Hachibu",
with no level and no status. Pressing it through accessibility (what
VoiceOver, Voice Control, and scripts do) reported success and opened
nothing.
Cause: on macOS 27 the system draws menu bar items itself. It passes on
the item's label and drops a separate accessibility value. A real click
reaches SwiftUI another way; a press through accessibility goes to the
item's button, which has no action.
Fix: the label now carries the level and the status ("Hachibu, Battery 80
percent, Holding at limit"). `StatusItemAccess` in `MenuBar.swift` gives
the item's button a press that opens a window with what the popover
shows. A real click still opens the popover.
Rule: check a control with the accessibility API from outside the app
(role, label, value, and what a press does), not by reading the
modifiers in the code. A modifier that is set is not a value that
arrives.

## A hot battery kept charging while Hachibu was reopened again and again

On 2026-11-21 the battery stayed above 40 °C for twelve minutes, up to
42.8 °C, and charging never paused. Heat protection waited three minutes
above the threshold, counted in memory only; during those twelve minutes
Hachibu was quit and reopened every one to three minutes by update and
Homebrew trials, so no copy ever counted three minutes. Fixed: the wait
is one minute, and at launch the time already spent above the threshold
is read from History's samples (`ChargeEngine.hotSince`).

Rule: a wait that protects the battery must not start again when the app
restarts; take it from something recorded on disk.

## "Paused for heat" with nothing asked, and a hold above the limit

Found by an outside review on 2026-11-22, in `HeatRule`. One percent
under the limit the hold came out equal to the limit, so the plan said
"paused" while nothing was asked of macOS and charging went on. And a
hold kept from before the user lowered the limit could sit above the new
limit and be asked for. Fixed: a hold is always below the limit; where
none fits, there is no pause; a hold at or above the limit is dropped.

Rule: a status may only be shown when the request that makes it true was
made. Test the edges of every hold against the limit: one under it, and
the limit moving under it.

## The menu bar icon stayed on the plug with the charger out

Seen on 2026-11-22 while trying the plug and bolt marks for real: with
Hachibu's window closed, the charger was out for 18 seconds and the item
kept its pins and "Holding at limit" the whole time. The monitor read
the battery only on its timer, every 20 seconds with the window closed.
Fixed: it also reads when macOS reports a power source change
(`IOPSNotificationCreateRunLoopSource`). Tried again with the window
closed: the unplug showed within 3 seconds.

Rule: what the menu bar item shows must follow events, not only a timer.
Try every state change with the popover closed; an open popover reads
ten times as often and hides the delay.
