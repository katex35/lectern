#!/bin/sh
# Draws Packaging/AppIcon.icns from the logo the app itself renders. Run it after the logo changes;
# the icon is kept in the repository so building needs no window.
set -eu

root=$(cd "$(dirname "$0")/.." && pwd)
swift build --package-path "$root" -c release --product Lectern
bin=$(swift build --package-path "$root" -c release --show-bin-path)

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
LECTERN_ICON="$work/icon.png" "$bin/Lectern"
iconset="$work/AppIcon.iconset"
mkdir "$iconset"
for size in 16 32 128 256 512; do
    double=$((size * 2))
    sips -z "$size" "$size" "$work/icon.png" --out "$iconset/icon_${size}x${size}.png" >/dev/null
    sips -z "$double" "$double" "$work/icon.png" --out "$iconset/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$iconset" -o "$root/Packaging/AppIcon.icns"
echo "$root/Packaging/AppIcon.icns"
