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

## Where to read next

- [`ARCHITECTURE.md`](../ARCHITECTURE.md): who decides and who acts.
- [`CLAUDE.md`](../CLAUDE.md): the layout of the code, the checks, and
  the design rules.
- [`design/KIT.md`](../design/KIT.md): the design kit.
- [`docs/research/charge-control.md`](research/charge-control.md): what
  was measured about charging on macOS 27.
