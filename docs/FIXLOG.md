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

