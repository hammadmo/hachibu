# Security

Hachibu installs a helper that runs as root, so reports about it are
taken seriously.

## Reporting a problem

Please do not open a public issue for a security problem. Use GitHub's
private report instead: on this repository open the **Security** tab and
choose **Report a vulnerability**. You will get an answer there.

Useful to include: the version of Hachibu (Settings > About), your macOS
version, and the steps that show the problem.

## What the helper is, and what protects it

- One short file: [`Sources/HachibuHelper/main.swift`](Sources/HachibuHelper/main.swift).
- It accepts three requests and nothing else: set a charge limit between
  15% and 100%, reconnect the charger, and report its status. Anything
  else is refused ([`Sources/HachibuKit/Helper.swift`](Sources/HachibuKit/Helper.swift)).
- It listens only to an app with Hachibu's identifier, signed by the same
  Apple developer team as the helper, and no older than the first build
  made with the hardened runtime. macOS checks this before a request
  reaches the helper.
- It is started by macOS when the app asks for it and quits ten seconds
  after the app lets go.
- It cannot cut the charger, run a command, or read or write a file of
  your choosing.

## Updates

Updates are downloaded over HTTPS and checked against Hachibu's update
key before they are unpacked or installed. The list of versions the app
reads (`appcast.xml` in this repository) is not signed itself: someone
who could change it could point at a download, but a download without a
valid signature is refused. Releases are also signed with a Developer ID and notarized by
Apple; the README shows how to check a download.
