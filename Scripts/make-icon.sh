#!/bin/zsh
# Renders the app icon (Scripts/make-icon.swift) and writes every macOS size
# into DvdForge/Assets.xcassets/AppIcon.appiconset.
set -euo pipefail

ROOT="${0:A:h:h}"
SET="$ROOT/DvdForge/Assets.xcassets/AppIcon.appiconset"
MASTER=$(mktemp -t dvdforge-icon).png
trap 'rm -f "$MASTER"' EXIT

swift "$ROOT/Scripts/make-icon.swift" "$MASTER" >/dev/null
mkdir -p "$SET"

images=()
for points in 16 32 128 256 512; do
  for scale in 1 2; do
    px=$((points * scale))
    suffix=""
    if [[ $scale == 2 ]]; then suffix="@2x"; fi
    name="icon_${points}x${points}${suffix}.png"
    sips -z $px $px "$MASTER" --out "$SET/$name" >/dev/null
    images+=("    { \"size\" : \"${points}x${points}\", \"idiom\" : \"mac\", \"filename\" : \"$name\", \"scale\" : \"${scale}x\" }")
  done
done

{
  echo '{'
  echo '  "images" : ['
  print -l -- "${(j:,\n:)images}"
  echo '  ],'
  echo '  "info" : { "version" : 1, "author" : "xcode" }'
  echo '}'
} > "$SET/Contents.json"

cat > "$ROOT/DvdForge/Assets.xcassets/Contents.json" <<'JSON'
{
  "info" : { "version" : 1, "author" : "xcode" }
}
JSON
echo "==> Wrote $SET"
