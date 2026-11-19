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
work=$(mktemp -d)
trap 'rm -rf $work' EXIT
for old in $before/*.png; do
  name=${old:t}
  count=$((count + 1))
  [[ -f $now/$name ]] || { echo "missing $name"; bad=$((bad + 1)); continue }
  # The window's close, minimize, and zoom buttons are painted over: they
  # are lit or grey depending on which window macOS thinks is active.
  # Then: pixels that differ by more than 1%, since capture is not bit-exact.
  magick $old -fill black -draw "rectangle 0,0 160,64" $work/a.png
  magick $now/$name -fill black -draw "rectangle 0,0 160,64" $work/b.png
  out=$(magick compare -metric AE -fuzz 1% $work/a.png $work/b.png null: 2>&1)
  code=$?
  # 0 is the same, 1 is different, 2 is an error such as two sizes. Only a
  # clean answer with a number counts as the same.
  diff=$(print -r -- "$out" | awk '{print int($1)}')
  if [[ $code -ge 2 || ! "$out" =~ '^[0-9]' ]]; then
    echo "$name cannot be compared: ${out[1,80]}"; bad=$((bad + 1))
  elif [[ $diff -gt 40 ]]; then
    echo "$name differs in $diff pixels"; bad=$((bad + 1))
  fi
done
for new in $now/*-(light|dark).png; do [[ -f $before/${new:t} ]] || echo "new page ${new:t}"; done
[[ $bad -eq 0 ]] && echo "SAME ($count pages)" || { echo "DIFFERENT ($bad of $count)"; exit 1 }
