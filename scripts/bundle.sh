#!/bin/sh
# Builds build/Lectern.app from the Swift package: the app and its recorder helper side by side,
# the translations where macOS looks for them, the icon, and a local signature.
#   scripts/bundle.sh          release build
#   scripts/bundle.sh debug    debug build
# LECTERN_SWIFT_FLAGS adds flags to swift build (Homebrew passes --disable-sandbox).
set -eu

root=$(cd "$(dirname "$0")/.." && pwd)
config=${1:-release}
app="$root/build/Lectern.app"
flags=${LECTERN_SWIFT_FLAGS:-}

# shellcheck disable=SC2086
swift build $flags --package-path "$root" -c "$config" --product Lectern
# shellcheck disable=SC2086
swift build $flags --package-path "$root" -c "$config" --product lectern-recorder
# shellcheck disable=SC2086
bin=$(swift build $flags --package-path "$root" -c "$config" --show-bin-path)

rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$bin/Lectern" "$bin/lectern-recorder" "$app/Contents/MacOS/"
cp "$root/Packaging/Info.plist" "$app/Contents/Info.plist"
for lang in en tr; do
    mkdir -p "$app/Contents/Resources/$lang.lproj"
    cp "$root/Sources/Lectern/Resources/$lang.lproj/Localizable.strings" \
        "$root/Packaging/$lang.lproj/InfoPlist.strings" "$app/Contents/Resources/$lang.lproj/"
done
# drawn from the logo by scripts/make-icon.sh
cp "$root/Packaging/AppIcon.icns" "$app/Contents/Resources/AppIcon.icns"

# signed for this Mac only: built on the Mac it runs on, macOS opens it without asking
for target in "$app/Contents/MacOS/lectern-recorder" "$app"; do
    codesign --force --options runtime --entitlements "$root/Packaging/Lectern.entitlements" --sign - "$target"
done
echo "$app"
