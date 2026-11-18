# Hachibu

A native macOS menu bar app in SwiftUI that controls when a MacBook
charges. It runs on this Mac only, with no server.

Starting a session: read `docs/STATUS.md` first. It says what is done,
what is next, what is not verified, and the decisions already made.
Update it when a milestone ends or a decision changes.

## Layout

- `Sources/Hachibu/` the app: a menu bar item (`MenuBar.swift`), its popover (`PopoverView.swift`), and the Settings and History windows. `App.swift` has the scenes. No Dock icon, no main window, no database yet.
- `Sources/Hachibu/BatteryMonitor.swift` watches the battery and the limit and applies the limit the user chooses. Views read everything from it.
- `Sources/Hachibu/SystemBattery.swift` reads the real battery (`SystemBattery`) and macOS's own charge limit (`ChargeLimit`).
- `Sources/HachibuSystem/` C and Objective-C: the battery controller (SMC) and the private PowerUI framework. Read `docs/research/charge-control.md` before touching it.
- `Sources/HachibuKit/` rules with no SwiftUI: status, limit source, the "Limit not holding" watch, formatting. Tests in `Tests/HachibuKitTests/`.
- `Sources/Hachibu/DesignKit/` the design kit. `design/KIT.md` is its spec.
- `Package.swift` a Swift package. There is no Xcode project.
- `build.sh` builds, signs, and installs `~/Applications/Hachibu.app`.
- `Icon/AppIcon.icon` the app icon, drawn by `tools/draw_icon.py` and compiled by `tools/make_icon.sh`.
- `docs/` the brief, the research, the stories, and the glossary.

## Build and check

- Build and install: `./build.sh`. Add `--open` to restart the app with the new build. The build shows warnings; fix them.
- Unit tests: `swift test --scratch-path ~/Library/Developer/Hachibu/test-build`.
- Self-test: `tools/selftest.sh`. It reads the real battery and the real limit, read-only, and exits 0 when every check passes. Add a check for every story with logic in `SelfTest.swift`.
- After every UI change, take snapshots and look at them: `tools/snap.sh`. It writes `/tmp/Hachibu-shots/<page>-light.png` and `-dark.png` for the popover states, every Settings tab, and History, then quits. `APP_SNAPSHOT_PAGES=popover,settings,history tools/snap.sh` limits the groups. A new popover state is a case in `PopoverPreview`.
- Every snapshot state is a fixture. Snapshots never read or change the real battery.
- Test runs set `APP_STORE`. With it set, the app never writes real preferences, registers login items, sends notifications, or changes the charge limit (`Store.isOverridden`). Keep that true for every new feature that changes something real.
- `Hachibu --set-limit <n>` changes the real limit through the same path as the slider. Run it only when the user has agreed to a real change, and restore the limit afterwards.
- Then check the grid: `tools/grid-lint.sh` and `swift tools/check-layout.swift /tmp/Hachibu-shots/*-layout.json`. Both print PASS.
- A change is done when the build has no errors or warnings, tests and checks pass, and you looked at the light and dark snapshots.
- Run commands one per line or joined with `&&`, never `;`, so a failing check stops a commit.

## Design rules

Hachibu has its own design kit. The spec is `design/KIT.md`; the code is
`Sources/Hachibu/DesignKit/`. Read the spec before building or changing a part.

- Everything uses kit parts only: the popover, the menu bar item, Settings, and History.
- Settings and History are plain `Window` scenes with a hidden title bar and `.kitWindow(width:)`, not a SwiftUI `Settings` scene. A new tab is a case in `SettingsTab`; a setting is a `SettingsRow` in a `SettingsSection`, saved in `Preferences`.
- A row for a feature this build cannot do yet is disabled and says why (`Capability`). Never a control that silently does nothing.
- Views read colors only from `Ink`, fonts only through `.kitType(...)`, sizes from `Metric` and `Space`, motion from `Motion`, icons from `KitIcon`. Never a hex color, `.font(.system...)`, or `systemName:` outside `DesignKit/`.
- Every part is a real control (a `Button` with a style, a slider with an accessibility representation) and has every state: rest, hover, pressed, selected, focused, disabled, in light and dark.
- Review a new or changed part in the gallery before it goes into a screen:
  `APP_STORE=/tmp/Hachibu-test.store APP_KIT_GALLERY=1 APP_SNAPSHOT=/tmp/Hachibu-kit ~/Applications/Hachibu.app/Contents/MacOS/Hachibu`
  writes `kit-gallery-light.png` and `kit-gallery-dark.png`. Add the part to `KitGallery.swift` first.
- Spacing comes from `Space` in `UI/Grid.swift`, on a 4 pt grid. Mark custom pages and cards with `.gridArea` and `.gridProbe`.
- Meaning never rests on color alone: a warning has an icon and words.
- Use the words in `docs/GLOSSARY.md` for every string on screen.
- Snapshots of History use sample data (`HistoryData.sample`): `APP_SNAPSHOT_PAGES=history tools/snap.sh` writes `history-day`, `-week`, `-month`, and `history-empty` (what it shows today).

## Skills

The bama plugin has a skill for each step: `mac-design` (design rules),
`design-system` (accent and tokens), `layout-grid`, `ux-design`,
`swift-swiftui`, `os-integrations`, `performance`, `build-and-verify`,
`test-mac-app`, `app-icon`, `user-stories`, and `improve-loop`. Use them.

## Git

- Commit after each working change, with a message that says what the user can now do.
