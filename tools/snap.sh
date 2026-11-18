#!/bin/zsh
# Snapshots of the popover states, Settings, and History in light and dark.
# Every state is a fixture: nothing reads or changes the real battery.
# Usage: tools/snap.sh            everything
#        APP_SNAPSHOT_PAGES=popover,settings,history tools/snap.sh
set -u
app=~/Applications/Hachibu.app/Contents/MacOS/Hachibu
store=/tmp/Hachibu-test.store
shots=/tmp/Hachibu-shots
# A crashed run leaves saved window state, and the next launch would wait on a "reopen windows?" alert.
rm -rf ~/Library/Saved\ Application\ State/app.hachibu.mac.savedState
# Seed data only fills an empty store, so start from nothing.
rm -f $store $store-shm $store-wal $store-health $store-selftest
rm -rf $shots
APP_STORE=$store APP_SNAPSHOT=$shots $app
