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
