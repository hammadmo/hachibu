#!/bin/zsh
# Runs the in-app self-test against a fresh store in /tmp. Exit code 0 when every check passed.
set -u
rm -rf ~/Library/Saved\ Application\ State/app.hachibu.mac.savedState
store=/tmp/Hachibu-self.store
rm -f $store $store-shm $store-wal $store-health $store-selftest
APP_STORE=$store ~/Applications/Hachibu.app/Contents/MacOS/Hachibu --selftest
