#!/bin/sh
# Builds build/Lectern.app from the Swift package: the app and its recorder helper side by side,
# the translations where macOS looks for them, the icon drawn from the logo, and a local signature.
#   scripts/bundle.sh          release build
#   scripts/bundle.sh debug    debug build
set -eu

root=$(cd "$(dirname "$0")/.." && pwd)
config=${1:-release}
app="$root/build/Lectern.app"

swift build --package-path "$root" -c "$config" --product Lectern
swift build --package-path "$root" -c "$config" --product lectern-recorder
bin=$(swift build --package-path "$root" -c "$config" --show-bin-path)

rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$bin/Lectern" "$bin/lectern-recorder" "$app/Contents/MacOS/"
cp "$root/Packaging/Info.plist" "$app/Contents/Info.plist"
for lang in en tr; do
    mkdir -p "$app/Contents/Resources/$lang.lproj"
    cp "$root/Sources/Lectern/Resources/$lang.lproj/Localizable.strings" \
        "$root/Packaging/$lang.lproj/InfoPlist.strings" "$app/Contents/Resources/$lang.lproj/"
done

# the app draws its own icon from the logo; it is cut into the sizes macOS wants
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
iconutil -c icns "$iconset" -o "$app/Contents/Resources/AppIcon.icns"

# signed for this Mac only; a build for other people needs a Developer ID and notarization
for target in "$app/Contents/MacOS/lectern-recorder" "$app"; do
    codesign --force --options runtime --entitlements "$root/Packaging/Lectern.entitlements" --sign - "$target"
done
echo "$app"
