# Glossary

One name per thing. Use these words in buttons, menus, titles, tooltips,
notifications, and errors.

## Things

| Term | Means | Not |
| --- | --- | --- |
| Limit | The battery percentage where charging stops | cap, threshold, max charge, target |
| Charger | The power adapter plugged into the Mac | adapter, AC, wall power, power source |
| Battery health | Maximum capacity now, as a percent of the design capacity | condition, capacity, wear |
| Cycles | The battery's cycle count | charge cycles, count |
| Power flow | Watts from the charger, used by the Mac, and into or out of the battery | wattage, energy, power draw |
| Helper | The background service that lets Hachibu set limits below 80% and sail | daemon, agent, service, tool |
| Sailing range | How many percent the battery drifts below the limit before it charges again | hysteresis, lower limit, drift |
| History | Recorded battery level, temperature, and power over time | stats, log, graphs |

## Status (one line in the popover)

| Term | Means | Not |
| --- | --- | --- |
| Charging | Plugged in and current is flowing into the battery | powering, filling |
| Holding at limit | Plugged in, at the limit, no current into the battery | limit reached, paused, idle, full |
| On battery | Not plugged in | unplugged, discharging |
| Fully charged | Plugged in at 100% with no current into the battery | full, charged |
| Not charging | Plugged in, away from the limit, and no current into the battery | paused, idle, waiting |
| Using battery | Plugged in, yet power is leaving the battery: macOS is draining it toward the limit, or the charger cannot keep up | discharging, draining |
| Topping up | Charging to 100% once, at the user's request | full charge, override, boost |
| Sailing | Plugged in, below the limit, and not charging: inside the sailing range | coasting, floating |
| Paused for heat | Charging stopped because the battery is above the set temperature | heat protection active, overheated |
| Full charge by macOS | macOS is charging past the limit on its own to keep its estimates accurate | calibration, override, top off |
| Limit not holding | The battery is charging above the limit and Hachibu did not ask for it | error, failed, limit exceeded |
| No limit | Charging goes to 100% | off, disabled, unlimited |

## Actions

| Term | Means | Not |
| --- | --- | --- |
| Set the limit | Choose the percentage where charging stops | change cap, adjust |
| Use Hachibu's Limit | Apply the limit saved in Hachibu when macOS holds a different one | restore, reset, take over |
| Keep This Limit | Adopt the limit macOS already holds as Hachibu's own | accept, import |
| Apply Limit Again | Ask macOS for the limit once more, from the warning banner | retry, fix |
| Top Up | Start charging to 100% once | charge to full, boost |
| Stop | End a Top Up or a calibration early | cancel, abort |
| Calibrate | Run a guided full charge, discharge, and charge | recalibrate, condition |
| Install Helper / Remove Helper | Add or delete the helper | enable, uninstall, register |
| Settings, Quit | Apple's words | Preferences, Exit |

## Limit source (under the limit)

| Term | Means | Not |
| --- | --- | --- |
| Set by Hachibu | The macOS limit matches the one saved in Hachibu | ours, managed |
| Set outside Hachibu | The macOS limit differs: System Settings or another app changed it | external, overridden, conflict |
