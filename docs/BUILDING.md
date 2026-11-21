# Building Hachibu

For people who want to build Hachibu from its source, change it, or make
a release. To just use it, download the
[latest release](https://github.com/hammadmo/hachibu/releases/latest).

## Build

You need an Apple silicon Mac with macOS 27 and Xcode 26 or later.
There is no Xcode project; Hachibu is a Swift package.

```bash
./build.sh --open
```

This builds a release, signs it, installs `~/Applications/Hachibu.app`,
and opens it. Other options:

| Option | What it does |
| --- | --- |
| `--debug` | A debug build instead of a release. |
| `--open` | Quits the running copy and opens the new one. |
| `--notarize` | Also sends the app to Apple's notary and staples the ticket. |

Set `APP_DIR=<folder>` to put the app somewhere other than
`~/Applications`, for looking at a build without replacing the copy that
is running. `tools/snap.sh` and `tools/selftest.sh` take `APP_BINARY=<path>`
to use it.

Build products go to `~/Library/Developer/Hachibu`, outside the
repository.

## Signing

The helper (limits below 80%, sailing, heat protection, calibration) can
only be installed from an app signed with an Apple certificate. So how
the build is signed decides what works:

| Signing | What you get |
| --- | --- |
| None (ad hoc) | macOS's own limits, 80 to 100%, and Top Up. The helper cannot be installed. |
| Apple Development certificate | Everything, on your own Mac. |
| Developer ID certificate | Everything, and a build you can give to others. |

`build.sh` picks the best certificate it finds in your keychain, in that
order from the bottom up. Set `SIGN_IDENTITY` to choose one yourself.

## Checks

```bash
swift test --scratch-path ~/Library/Developer/Hachibu/test-build
```

```bash
tools/selftest.sh
```

```bash
tools/snap.sh
```

The unit tests cover the rules in `Sources/HachibuKit`. The self-test
reads the real battery and limit without changing them. `tools/snap.sh`
writes light and dark pictures of every screen to `/tmp/Hachibu-shots`,
from sample data.

## Making a release

1. Save a notary login once: `xcrun notarytool store-credentials hachibu`.
2. Build, notarize, and staple:

```bash
./build.sh --notarize
```

3. Zip the stapled app. Use `ditto`, which keeps the signature intact:

```bash
ditto -c -k --keepParent ~/Applications/Hachibu.app ~/Library/Developer/Hachibu/dist/Hachibu-<version>.zip
```

4. Create the release on GitHub with that zip, and put its `shasum -a 256`
   in the notes.
5. Tell installed copies about it. Hachibu updates itself with
   [Sparkle](https://sparkle-project.org), which reads `appcast.xml` at
   the top of this repository. Sparkle's `generate_appcast` writes that
   file from the folder of zips and signs each entry with the update
   key in your keychain:

```bash
~/Library/Developer/Hachibu/build/artifacts/sparkle/Sparkle/bin/generate_appcast --account hachibu --maximum-deltas 0 --download-url-prefix https://github.com/hammadmo/hachibu/releases/download/v<version>/ -o appcast.xml ~/Library/Developer/Hachibu/dist
```

   Keep only the newest zip in that folder when you run it: the address
   prefix is used for every zip it finds. Commit and push `appcast.xml`. Copies of Hachibu find the new version
   within a day.

The update key was made once with Sparkle's `generate_keys --account hachibu`.
Its private half lives only in the maintainer's login keychain; its
public half is `SUPublicEDKey` in `Info.plist.in`. A build signed by
anyone else is refused by every installed copy. Keep a backup of the key
(`generate_keys --account hachibu -x <file>`): without it no update can
reach the copies already installed.

Set `CFBundleShortVersionString` in `Info.plist.in` to the new version
before building. Sparkle compares build numbers, which `build.sh` makes
from the date and time, so a later build is always newer.

## Where to read next

- [`ARCHITECTURE.md`](../ARCHITECTURE.md): who decides and who acts.
- [`CLAUDE.md`](../CLAUDE.md): the layout of the code, the checks, and
  the design rules.
- [`design/KIT.md`](../design/KIT.md): the design kit.
- [`docs/research/charge-control.md`](research/charge-control.md): what
  was measured about charging on macOS 27.

## README pictures

`docs/images/hero.png` and `docs/images/popover.gif` are made from the
popover snapshots, each under a piece of menu bar with the icon for its
state. After a change to the popover or the menu bar icon:

```bash
APP_SNAPSHOT_PAGES=popover tools/snap.sh && tools/readme-images.sh
```
