# Hachibu design kit

## Feel
Three words: quiet, precise, lacquered. An ink brush circle (ensō) that is
deliberately left open is the gauge: the gap is the charge you leave
unused. Light mode is ink on warm paper. Dark mode is gold on black
lacquer. A small vermilion seal is the only bright color.

Scope: everything is kit: the popover, the menu bar item, Settings, and
History. Traffic lights, menus, and alerts stay system.

## Tokens

### Palette (`Pigment`, read only by `Tokens.swift`)
| Name | Hex | Role |
| --- | --- | --- |
| paper | #F4EFE6 | light surface |
| paperDeep | #ECE5D7 | light raised card |
| paperLine | #DDD3C0 | light hairline |
| paperTick | #CFC3AB | light tick ring |
| ink | #1F1B16 | light text, ring, fills |
| inkSoft | #6F6558 | light secondary text (5.0:1 on paper) |
| lacquer | #100D0C | dark surface |
| lacquerRaised | #1A1613 | dark raised card |
| lacquerLine | #2A2218 | dark hairline |
| lacquerTick | #3F3320 | dark tick ring |
| cream | #EADFC8 | dark text |
| creamSoft | #9A8D75 | dark secondary text (6.0:1 on lacquer) |
| gold | #C9A45C | dark ring, fills, accents |
| goldMid | #A07C2C | light accents (slider thumb, limit line) |
| goldDeep | #7F6119 | light accent text (5.2:1 on paper) |
| goldDim | #6B5935 | dark outlines |
| seal | #B4322A | the seal, the limit dot, warning fills |
| sealBright | #E0685C | dark warning text (5.6:1 on lacquer) |
| sealPaper | #F4E9D6 | text on the seal |

### Meaning (`Ink`, the only colors parts read)
| Token | Light / Dark | Used for |
| --- | --- | --- |
| surface | paper / lacquer | popover background |
| raised | paperDeep / lacquerRaised | cards |
| hairline | paperLine / lacquerLine | card borders, slider track, dividers |
| tick | paperTick / lacquerTick | gauge tick ring |
| relief | #E3D8C3 / #2B2115 | tone-on-tone decoration: the wave pattern |
| text | ink / cream | primary text, numerals |
| textSoft | inkSoft / creamSoft | labels, captions |
| gauge | ink / gold | the brush ring, slider fill, chart line |
| accent | goldMid / gold | slider thumb, limit line, focus ring |
| accentText | goldDeep / gold | emphasized values |
| fill | ink / gold | primary button |
| onFill | paper / lacquer | text on the primary button |
| outline | ink / goldDim | secondary button border |
| outlineText | ink / gold | secondary button text |
| wash | ink 10% / gold 10% | hover fills |
| seal | seal / seal | seal mark, limit dot |
| onSeal | sealPaper | character on the seal |
| warning | seal / sealBright | warning text and icons, warning ring |
| warningWash | seal 16% | warning banner fill |

Why the ring is ink in light mode: gold on paper is 2.3:1, too faint for
the one shape that carries the reading.

### Metric
| Token | Value | Why |
| --- | --- | --- |
| popoverWidth | 320 | fits three power values and two buttons |
| gaugeSize | 160 | hero; half the popover width |
| gaugeSmall | 112 | gallery and compact use |
| gaugeStroke | 13 | brush width at its fullest, at gaugeSize; bold enough to carry the brush detail |
| tickCount / tickLength | 60 / 4 | one tick per 6°, like a dial |
| limitDot | 3 | radius of the limit mark on the tick ring |
| sealSize / sealSmall | 20 / 12 | seal mark |
| sealRadius | 3 | a carved stamp, nearly square |
| buttonHeight | 32 | |
| buttonRadius | 4 | crisp, like a lacquer box; not a pill |
| cardRadius | 8 | |
| sliderHeight / Track / Thumb | 24 / 2 / 12 | |
| sparkHeight | 48 | |
| hairline / focusRing | 1 / 2 | |
| iconSize | 14 | |

Spacing uses `Space` (4 pt grid) from `UI/Grid.swift`.

### Motion
| Token | Curve | Used for |
| --- | --- | --- |
| hover | ease out 0.12 s | hover fills |
| press | spring 0.25 s, damping 0.7 | button and thumb press |
| gauge | ease in-out 0.6 s | the ring following the battery level |

Reduce Motion: the ring jumps to its new length; no other motion carries
meaning.

## Type
Numerals are serif (New York, the system serif). Everything else is the
system sans.

| Role | Font | Size | Weight | Used for |
| --- | --- | --- | --- | --- |
| gaugeNumeral | serif | 44 | regular | the percentage in the ring |
| gaugeNumeralSmall | serif | 28 | regular | the percentage in a small ring |
| numeral | serif | 15 | regular | watts and other values |
| title | serif | 22 | regular | the app name in About |
| status | sans | 14 | medium | the status line, tabs |
| body | sans | 13 | regular | settings rows, paragraphs |
| section | sans | 11 | medium | settings section titles |
| label | sans | 12 | regular | controls, captions |
| labelStrong | sans | 12 | medium | buttons, banner titles |
| meta | sans | 11 | regular | units, sources, stat rows |
| seal / sealSmall | sans | 11 / 8 | medium | the character on the seal |

All numerals use monospaced digits so values do not shift as they change.

## Icons
Source: SF Symbols, light weight, 14 pt, never filled. Views name a
`KitIcon`. One drawn glyph: `EnsoGlyph`, the battery with a brush ring
for the menu bar, drawn as a template (one color, set by the menu bar).

| KitIcon | Symbol |
| --- | --- |
| charger | powerplug |
| mac | laptopcomputer |
| battery | minus.plus.batteryblock |
| flow | arrow.right |
| warning | exclamationmark.triangle |
| heat | thermometer.medium |
| history | chart.xyaxis.line |
| settings | gearshape |

## Window
The popover is a `MenuBarExtra` window: no title bar, `Ink.surface`
background edge to edge, padding `Space.lg`, width `popoverWidth`.
Settings is a plain `Window` with a hidden title bar (a SwiftUI `Settings`
scene cannot hide its title bar), `Ink.surface` edge to edge, width 520,
height fitting the tab. Traffic lights stay where macOS puts them; the tab
bar starts 36 pt down to clear them. Command-Comma opens it.
History is the same kind of window, width 760, opened with Command-Y.
Both use `.kitWindow(width:)` (`DesignKit/KitWindow.swift`), which adds
the surface, the wave band, and the blossom sprig.

## Parts

### Ensō gauge (`EnsoGauge`)
Anatomy: tick ring (60 ticks, `Ink.tick`); limit dot on the tick ring at
the limit's angle (`Ink.seal`); one brush stroke from 12 o'clock clockwise
to the battery level; dust after the brush tip; serif numeral centered;
seal mark bottom trailing, tilted 5° like a hand stamp.
The stroke is hand-painted, by the same recipe as the app icon
(`Brush` in `EnsoGauge.swift`, `tools/draw_icon.py`): a pool of ink where
the brush lands, a slight waver, a drift inward late in the stroke, five
dry bristle streaks at the end (kasure), and three slivers where the
surface shows through. Dust (ink spatter in light mode, gold dust in dark)
drifts from the tip into the gap, never further than a fifth of the circle.
Size: `gaugeSize` or `gaugeSmall`; stroke and ticks scale with size.
| State | Ring | Numeral | Limit dot |
| --- | --- | --- | --- |
| normal | gauge | text | seal |
| warning (limit not holding) | warning | warning | seal |
| no reading | none; tick ring only | "–" in textSoft | hidden |
| no limit (100%) | gauge | text | hidden |
VoiceOver: one element, "Battery", value "80 percent, limit 80 percent".

### Seal mark (`SealMark`)
A rounded square in `Ink.seal` with 八 (eight) in `Ink.onSeal`.
Decorative: hidden from VoiceOver. Never used as a button.

### Menu bar glyph (`EnsoGlyph`)
A small battery, 22 by 16 pt, template: a rounded outline (radius 5,
line 1.1) with a terminal on the right. Inside, the charge is an enso: a
brush ring from 12 o'clock, clockwise, as long as the battery is full,
2.9 pt where the brush lands and 0.9 pt where it lifts. No reading: a
dotted ring. The terminal says where power comes from: the plain
terminal on battery; two plug pins (4.9 by 2 pt) in its place on the
charger without charging, so the battery reads as a plug; a 13 pt bolt
across the right edge while charging, with 1 pt cleared around it. The
icon is 22, 23, or 25 pt wide for the three. A warning adds an exclamation mark beside it, never color
alone. The gallery draws it with the menu bar's own code (`MenuBarGlyph`).

### Button (`.buttonStyle(.kit(kind))`)
Size: height 32, radius 4, horizontal padding 12, `labelStrong`.
| State | Primary | Secondary | Ghost |
| --- | --- | --- | --- |
| rest | fill, onFill text | outline 1, outlineText | textSoft |
| hover | fill 88% | wash fill | text, wash fill |
| pressed | fill 76%, scale 0.98 | wash fill, scale 0.98 | wash fill |
| selected | as hover (an active mode, for example Top Up running) | wash fill, accent border | text |
| focused | accent ring 2, offset 2 | same | same |
| disabled | 40% | 40% | 40% |

### Limit slider (`LimitSlider`)
Anatomy: track 2 pt (`Ink.hairline`), fill up to the thumb (`Ink.gauge`),
thumb 12 pt circle (`Ink.accent`). Snaps to stops. The track always shows
20 to 100%, so 80% sits in one place; the part below the first stop is
dashed (`Ink.tick`) and cannot be reached until the helper is installed.
| State | Thumb | Track |
| --- | --- | --- |
| rest | accent | hairline + gauge fill |
| hover | accent, wash halo 4 | same |
| pressed | accent, scale 1.15 | same |
| selected | as rest | same |
| focused | accent ring 2 around the thumb | same |
| disabled | 40% | 40% |
Keyboard: left and down go to the previous stop, right and up to the
next. VoiceOver: a system slider, "Limit, 80 percent".

### Card (`.kitCard()`)
Fill `Ink.raised`, border `Ink.hairline` 1, radius 8, padding `Space.md`.

### Power flow card (`PowerFlowCard`)
Three columns: Charger, Mac, Battery. Label in `meta` + `textSoft`; value
in `numeral`. Flow arrows between columns in `textSoft`. The charger
value is `accentText` while power comes in. A missing value shows "–".

### Status line (`StatusLine`)
Title in `status` + `text`; detail in `meta` + `textSoft`, centered.

### Stat row (`StatRow`)
Up to three "label value" pairs in `meta`, spread across the width.

### Level sparkline (`LevelSparkline`)
A 24-hour line in `Ink.gauge`, stroke 2, round joins; the limit as a
dashed 1 pt line in `Ink.accent`. Height 48. The scale runs from ten
below the lowest level (in tens) to 100. Under an hour of data:
"Collecting data" in `meta`.

### Banner (`KitBanner`)
Fill `Ink.warningWash`, border `Ink.warning` 1, radius 8. Warning icon
and title in `Ink.warning` + `labelStrong`; message in `meta` + `text`;
one secondary button.

### Dialog (`KitDialog`)
A card 336 wide over a dimmed window (`Ink.scrim`): title, one line of
explanation, numbered steps, and at most two buttons (ghost, then
primary) at the trailing edge. A `progress` line replaces the buttons
while Hachibu is busy. With `currentStep`, that step is in `labelStrong`
and the others soften; a `note` under the steps is small print in `meta`. Only for something the person must do outside
Hachibu, such as allowing the helper in Login Items.

### Toggle (`.toggleStyle(.kit)`)
Size 36 x 20, thumb 14.
| State | Off | On |
| --- | --- | --- |
| rest | outline 1, thumb textSoft | fill, thumb onFill |
| hover | wash fill | fill 88% |
| pressed | wash fill, thumb scale 0.88 | thumb scale 0.88 |
| focused | accent ring 2, offset 2 | same |
| disabled | 40% | 40% |
VoiceOver: a system toggle with the row's title.

### Tab bar (`KitTabBar`)
Text tabs, height 36, `status` type. Left and right arrows move.
| State | Text | Mark |
| --- | --- | --- |
| rest | textSoft | none |
| hover, pressed | text | wash fill |
| selected | text | accent underline 2 |
| focused | text | accent ring 2 |
| disabled | 40% | none |

### Settings section and row (`SettingsSection`, `SettingsRow`)
Section: title in `section` + `accentText`, then one card (`Ink.raised`,
hairline border, radius 8) with hairlines between rows, inset 16.
Row: min height 44, padding 16 x 12. Title in `body` + `text`; detail in
`meta` + `textSoft`; the control on the trailing edge.
A row for something this build cannot do yet is disabled and says why in
its detail. It never looks like a working control.

### Status pill (`StatusPill`)
A dot 8 pt and a word in `body`: idle (textSoft), good (accent), warning
(warning). Never the dot alone.

### Chart and chart card (`KitChart`, `ChartCard`)
Chart: height 120; three hairlines (top, middle, bottom); the main line
in `Ink.gauge`, 2 pt, round joins, with a `Ink.wash` fill beneath; a second
line in `Ink.textSoft`, 1 pt; a guide (the limit) dashed 1 pt in
`Ink.accent`; scale labels in `meta` at the top and bottom trailing corners.
Pointer over the chart: a vertical hairline, a 6 pt `Ink.accent` dot on
each line, the value in the card header, and the time under the chart.
Card: title in `section` + `accentText`; the latest value (or a summary)
in `numeral`; the chart; the range's start and "Now" in `meta`, with a
legend between them when there are two lines.
VoiceOver: one element per card, the title and the latest value.
The vertical scale sits on round numbers (`ChartScale` in HachibuKit).

### History empty state
The gauge with no reading (tick ring and a dash), "No history yet" in
`status`, and one sentence in `body` + `textSoft` saying why.

### Motifs (`Seigaiha`, `UmeBlossom`)
The two motifs from the app icon, for quiet decoration only. Hidden from
VoiceOver; they never carry meaning and never sit behind text.
- Seigaiha (waves, calm seas): scales of radius 24, three arcs each,
  stroked 1 pt in `Ink.relief`. A band 64 pt tall along the bottom edge of
  the Settings window, higher on the leading side.
- Ume (plum blossom): petals in `Ink.accent`, stamens in `Ink.seal`.
  A sprig (two flowers, three loose petals) at 55% in the top trailing
  corner of every kit window; a single 16 pt flower in the middle of
  the divider on the About tab.
Not used in the popover: it is dense with numbers.

### Popover composition (`PopoverView`)
Top to bottom, spacing `Space.lg`: the warning banner (only while the
limit is not holding); the gauge; the status line (status, then measured
watts); the power flow card; the limit block (label and value, slider,
then the source with one secondary button when there is something to do:
"Use Hachibu's Limit" or "Keep This Limit"); the stat row; a divider; the
footer. Under the limit block sits one secondary button, "Top Up", which
reads "Stop" and is selected while a Top Up runs. The 24-hour chart joins
when it is built, not before.

### Footer
Ghost buttons in a row: "History…", "Settings…", "Quit Hachibu".
