#!/bin/zsh
# Remakes docs/images/hero.png and docs/images/popover.gif: the popover
# snapshots, each under a piece of menu bar with the icon for its state.
# Usage: APP_SNAPSHOT_PAGES=popover tools/snap.sh && tools/readme-images.sh
set -eu
cd ${0:a:h}/..
work=$(mktemp -d)
# The icon is drawn by the menu bar's own code, taken from the app's source.
cat tools/readme_images.swift > $work/main.swift
sed -n '/^nonisolated enum MenuBarGlyph/,$p' Sources/Hachibu/MenuBar.swift >> $work/main.swift
swiftc -O -o $work/readme-images $work/main.swift
$work/readme-images /tmp/Hachibu-shots docs/images
rm -rf $work
