#!/bin/sh
# Regenerates the app icon and launch logo, and the web app's favicons. Needs ImageMagick.
# Usage: scripts/make-icons.sh [mark.png]
#
# The mark defaults to Branding/mark.png, rendered from Branding/mark.svg. Any PNG with a
# transparent background works. The favicons go to the web repo when it is cloned next to this
# one, or to SOLOBILL_WEB if that is set.
set -eu

root="$(cd "$(dirname "$0")/.." && pwd)"
assets="$root/Solobill/Resources/Assets.xcassets"
web="${SOLOBILL_WEB:-$root/../solobill}/src/client"
source="${1:-$root/Branding/mark.png}"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

magick "$source" -trim +repage -resize 620x620 -background none -gravity center \
  -extent 1024x1024 "$work/mark.png"

# The Octax gradient. App icons must be square and fully opaque, because iOS applies the rounded
# corners itself.
magick -size 1024x1024 -define gradient:angle=135 gradient:'#8B5CF6-#2F86F2' \
  "$work/mark.png" -gravity center -composite -alpha off "$assets/AppIcon.appiconset/AppIcon.png"

# Without these iOS derives its own dark and tinted icons, and the result is unreadable.
cp "$assets/AppIcon.appiconset/AppIcon.png" "$assets/AppIcon.appiconset/AppIcon-Dark.png"
magick -size 1024x1024 xc:black "$work/mark.png" -gravity center -composite -alpha off \
  -colorspace Gray "$assets/AppIcon.appiconset/AppIcon-Tinted.png"

for scale in 1 2 3; do
  size=$((200 * scale))
  suffix=""
  [ "$scale" -gt 1 ] && suffix="@${scale}x"
  magick "$work/mark.png" -trim +repage -resize "${size}x${size}" -background none \
    -gravity center -extent "${size}x${size}" "$assets/LaunchLogo.imageset/LaunchLogo$suffix.png"
done

icon="$assets/AppIcon.appiconset/AppIcon.png"
if [ -d "$web" ]; then
  magick "$icon" -resize 64x64 \( -size 64x64 xc:none -fill white -draw 'roundrectangle 0,0 63,63 14,14' \) \
    -compose CopyOpacity -composite "$web/favicon.png"
  magick "$icon" -resize 180x180 "$web/apple-touch-icon.png"
  echo "Updated the favicons in $web"
else
  echo "Skipped the favicons: no web repo at $web"
fi
