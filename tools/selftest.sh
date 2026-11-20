#!/bin/zsh
# Runs the in-app self-test against a fresh store in /tmp. Exit code 0 when every check passed.
set -u
rm -rf ~/Library/Saved\ Application\ State/app.hachibu.mac.savedState
store=/tmp/Hachibu-self.store
rm -f $store $store-shm $store-wal $store-health $store-selftest
# APP_BINARY tests another build, such as one made with APP_DIR.
APP_STORE=$store ${APP_BINARY:-~/Applications/Hachibu.app/Contents/MacOS/Hachibu} --selftest
