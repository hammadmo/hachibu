# Hachibu

A native macOS app in SwiftUI. It runs on this Mac only, with a local
SwiftData database and no server.

## Layout

- `Sources/Hachibu/` the app. `App.swift` has the window, menus, and the database location.
- `Sources/HachibuKit/` rules and data logic with no SwiftUI. Tests in `Tests/HachibuKitTests/`.
- `Package.swift` a Swift package. There is no Xcode project.
- `build.sh` builds, signs, and installs `~/Applications/Hachibu.app`.
- `Icon/AppIcon.icon` the app icon, an Icon Composer file (JSON plus SVG layers). `build.sh` compiles it with `tools/make_icon.sh`; `tools/icon_review.sh` renders every look into one PNG.
- `docs/` the brief, the screen index, and the user stories, when they exist.

## Build and check

- Build and install: `./build.sh`. Add `--open` to restart the app with the new build. The build shows warnings; fix them.
- Unit tests: `swift test --scratch-path ~/Library/Developer/Hachibu/test-build`.
- Self-test (the app's real functions on a /tmp store): `tools/selftest.sh`. Exit 0 when every check passes. Add a check for every story with logic in `SelfTest.swift`.
- After every UI change, take snapshots with sample data and look at them: `tools/snap.sh`.
  It writes `/tmp/Hachibu-shots/<page>-light.png` and `-dark.png` for every sidebar page, and `settings-<tab>-light.png` and `-dark.png` for every Settings tab, then quits. `APP_SNAPSHOT_PAGES=all,settings tools/snap.sh` limits the pages.
  For a panel, sheet, or popover, add a capture to `Snapshot.swift` like the Settings loop.
- Snapshots, seed data, and the self-test refuse to run without `APP_STORE` in /tmp.
- Never test against the real database in `~/Library/Application Support/Hachibu/`.
- Then check the grid: `tools/grid-lint.sh` and `swift tools/check-layout.swift /tmp/Hachibu-shots/*-layout.json`. Both print PASS.
- A change is done when the build has no errors, the grid checks pass, and you looked at the light and dark snapshots.

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
