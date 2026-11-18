#!/bin/zsh
# Compares the snapshots in /tmp/Hachibu-shots with a saved copy, for
# refactors that must not change what is on screen.
# Usage: tools/compare-shots.sh <folder with the earlier snapshots>
# Prints one line per page that differs, then SAME or DIFFERENT. Needs ImageMagick.
set -u
before=${1:?usage: tools/compare-shots.sh <baseline folder>}
now=/tmp/Hachibu-shots
bad=0
count=0
for old in $before/*.png; do
  name=${old:t}
  count=$((count + 1))
  [[ -f $now/$name ]] || { echo "missing $name"; bad=$((bad + 1)); continue }
  # The window's close, minimize, and zoom buttons are painted over: they
  # are lit or grey depending on which window macOS thinks is active.
  # Then: pixels that differ by more than 1%, since capture is not bit-exact.
  mask=(-fill black -draw "rectangle 0,0 120,64")
  diff=$(magick compare -metric AE -fuzz 1% \( $old $mask \) \( $now/$name $mask \) null: 2>&1 | awk '{print int($1)}')
  [[ ${diff:-1} -le 40 ]] || { echo "$name differs in $diff pixels"; bad=$((bad + 1)) }
done
for new in $now/*-(light|dark).png; do [[ -f $before/${new:t} ]] || echo "new page ${new:t}"; done
[[ $bad -eq 0 ]] && echo "SAME ($count pages)" || { echo "DIFFERENT ($bad of $count)"; exit 1 }
