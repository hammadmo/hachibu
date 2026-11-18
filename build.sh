#!/bin/zsh
# Builds Hachibu and installs it to ~/Applications/Hachibu.app.
# Build products live in ~/Library/Developer/Hachibu, outside the repo
# (and outside Dropbox or iCloud, which would try to sync them).
#
# Usage: ./build.sh            release build, install
#        ./build.sh --debug    debug build, install
#        ./build.sh --open     install, then quit the running copy and open the new one
#        ./build.sh --notarize also send the app to Apple's notary and staple the ticket.
#                              Needs a Developer ID certificate and a saved login:
#                              xcrun notarytool store-credentials hachibu
set -euo pipefail
here=${0:A:h}
name="Hachibu"
scratch="$HOME/Library/Developer/$name/build"
config=release
[[ " $* " == *" --debug "* ]] && config=debug

# Sign with a Developer ID certificate when there is one (needed to give the
# app to others), else an Apple Development certificate (enough for the
# helper on your own Mac), else ad hoc (the app works, the helper cannot be
# installed).
identity="${SIGN_IDENTITY:-}"
if [[ -z "$identity" ]]; then
  ids=$(security find-identity -v -p codesigning 2>/dev/null || true)
  identity=$(print -r -- "$ids" | grep -m1 -o '"Developer ID Application: [^"]*"' | tr -d '"' || true)
  [[ -n "$identity" ]] || identity=$(print -r -- "$ids" | grep -m1 -o '"Apple Development: [^"]*"' | tr -d '"' || true)
fi
[[ -n "$identity" ]] || identity=-

swift build -c $config --package-path "$here" --scratch-path "$scratch" 2>&1 | grep -E "error|warning|Build complete" | grep -v "^\[" || true
bin="$scratch/$config/$name"
helper="$scratch/$config/HachibuHelper"
[[ -x "$bin" && -x "$helper" ]] || { echo "build failed"; exit 1; }
# swift build can report success while an edited file failed to compile. Catch that.
# A source file newer than both programs was not compiled into either.
stale=$(find "$here/Sources" -name '*.swift' -newer "$bin" -newer "$helper" | head -1)
if [[ -n "$stale" ]]; then
  echo "build failed: binary is older than $stale"
  swift build -c $config --package-path "$here" --scratch-path "$scratch" 2>&1 | grep -E "error" | head -20
  exit 1
fi

app="$HOME/Applications/$name.app"
mkdir -p "$HOME/Applications"
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$bin" "$app/Contents/MacOS/$name"
# The helper and the file that tells macOS how to start it.
mkdir -p "$app/Contents/Library/LaunchDaemons"
cp "$helper" "$app/Contents/MacOS/HachibuHelper"
cp "$here/app.hachibu.mac.helper.plist" "$app/Contents/Library/LaunchDaemons/"
sed -e "s/__BUILD__/$(date +%Y%m%d%H%M)/" "$here/Info.plist.in" > "$app/Contents/Info.plist"
# The icon: Icon/AppIcon.icon -> Resources/Assets.car + AppIcon.icns, rebuilt when it changed.
if [[ -d "$here/Icon/AppIcon.icon" ]]; then
  car="$here/Resources/Assets.car"
  if [[ ! -f "$car" || -n "$(find "$here/Icon/AppIcon.icon" -newer "$car" | head -1)" ]]; then
    "$here/tools/make_icon.sh"
  fi
  cp -X "$car" "$here/Resources/AppIcon.icns" "$app/Contents/Resources/"
fi
xattr -cr "$app"
# Inside out: the helper first, under its own name, then the app around it.
sign=(codesign --force --sign "$identity")
if [[ "$identity" != - ]]; then
  sign+=(--options runtime)
  [[ "$identity" == "Developer ID"* ]] && sign+=(--timestamp)
fi
"${sign[@]}" --identifier app.hachibu.mac.helper "$app/Contents/MacOS/HachibuHelper" 2>&1 | grep -v "replacing existing signature" || true
"${sign[@]}" "$app" 2>&1 | grep -v "replacing existing signature" || true
codesign --verify --deep --strict "$app"
echo "installed $app (signed: ${identity%%:*})"

if [[ " $* " == *" --notarize "* ]]; then
  [[ "$identity" == "Developer ID"* ]] || { echo "notarizing needs a Developer ID Application certificate"; exit 1; }
  zip="$scratch/$name.zip"
  ditto -c -k --keepParent "$app" "$zip"
  xcrun notarytool submit "$zip" --keychain-profile "${NOTARY_PROFILE:-hachibu}" --wait
  xcrun stapler staple "$app"
  echo "notarized $app"
fi

if [[ " $* " == *" --open "* ]]; then
  osascript -e "quit app \"$name\"" 2>/dev/null || true
  sleep 0.5
  open "$app"
fi
