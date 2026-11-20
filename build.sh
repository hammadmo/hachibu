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

# The build's own exit code decides. A failed build must never install the
# program from the build before it.
log=$(swift build -c $config --package-path "$here" --scratch-path "$scratch" 2>&1) && built=1 || built=0
print -r -- "$log" | grep -E "error|warning|Build complete" | grep -v "^\[" || true
bin="$scratch/$config/$name"
helper="$scratch/$config/HachibuHelper"
sparkle="$scratch/$config/Sparkle.framework"
[[ $built -eq 1 && -x "$bin" && -x "$helper" && -d "$sparkle" ]] || { echo "build failed: nothing was installed"; exit 1; }

# APP_DIR puts the app somewhere else, to look at a build without replacing
# the copy that is running.
dest="${APP_DIR:-$HOME/Applications}"
app="$dest/$name.app"
mkdir -p "$dest"
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$bin" "$app/Contents/MacOS/$name"
# Sparkle (updates) goes inside the app, and the program looks for it there.
# The build also leaves a folder of this Mac in the program's search paths:
# take every such path out, so no build carries where it was made.
mkdir -p "$app/Contents/Frameworks"
ditto "$sparkle" "$app/Contents/Frameworks/Sparkle.framework"
for rpath in $(otool -l "$app/Contents/MacOS/$name" | awk '/LC_RPATH/ { getline; getline; print $2 }'); do
  [[ "$rpath" == /* ]] && install_name_tool -delete_rpath "$rpath" "$app/Contents/MacOS/$name" 2>/dev/null
done
install_name_tool -add_rpath @executable_path/../Frameworks "$app/Contents/MacOS/$name" 2>/dev/null
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
# Sparkle's own programs, each signed before the framework around them.
sp="$app/Contents/Frameworks/Sparkle.framework/Versions/B"
{
  "${sign[@]}" "$sp/XPCServices/Installer.xpc"
  "${sign[@]}" --preserve-metadata=entitlements "$sp/XPCServices/Downloader.xpc"
  "${sign[@]}" "$sp/Autoupdate"
  "${sign[@]}" "$sp/Updater.app"
  "${sign[@]}" "$app/Contents/Frameworks/Sparkle.framework"
} 2>&1 | grep -v "replacing existing signature" || true
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
