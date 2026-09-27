#!/bin/bash
# Builds "build/Siftr.app" for Apple Silicon Macs, plus a zip of it
# to share. Needs only Apple's free Command Line Tools (xcode-select --install).
#
#   ./build.sh              Apple Silicon (arm64)
#   ./build.sh --universal  Apple Silicon + Intel in one app
set -euo pipefail
cd "$(dirname "$0")"

APP="build/Siftr.app"
MIN_MACOS=14.0

# Each chip type builds in its own folder (SwiftPM trips over switching back
# and forth in one). A failed build stops the script.
swift_build() {  # $1 = arm64 | x86_64, then any extra options
  local arch=$1; shift
  swift build -c release --triple "$arch-apple-macosx$MIN_MACOS" --scratch-path ".build/$arch" "$@"
}
build_arch() {
  swift_build "$1" -Xswiftc -Osize -Xlinker -dead_strip
  echo "$(swift_build "$1" --show-bin-path)/Siftr" > ".build/$1.path"
}

echo "Building..."
mkdir -p build
build_arch arm64
bin=$(cat .build/arm64.path)
if [[ "${1:-}" == "--universal" ]]; then
  build_arch x86_64
  lipo -create "$bin" "$(cat .build/x86_64.path)" -output .build/Siftr-universal
  bin=.build/Siftr-universal
fi

echo "Assembling $APP..."
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/web"
cp "$bin" "$APP/Contents/MacOS/Siftr"
strip -x "$APP/Contents/MacOS/Siftr"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/web/*.html Resources/web/*.css Resources/web/*.js "$APP/Contents/Resources/web/"

# The icon: drawn by scripts/make_icon.swift, cached in Resources/AppIcon.icns
if [[ ! -f Resources/AppIcon.icns ]]; then
  echo "Drawing the icon..."
  tmp=$(mktemp -d)
  swift scripts/make_icon.swift "$tmp/icon.png" >/dev/null
  mkdir "$tmp/AppIcon.iconset"
  for s in 16 32 128 256 512; do
    sips -z $s $s "$tmp/icon.png" --out "$tmp/AppIcon.iconset/icon_${s}x${s}.png" >/dev/null
    sips -z $((s * 2)) $((s * 2)) "$tmp/icon.png" --out "$tmp/AppIcon.iconset/icon_${s}x${s}@2x.png" >/dev/null
  done
  iconutil -c icns "$tmp/AppIcon.iconset" -o Resources/AppIcon.icns
  rm -rf "$tmp"
fi
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

# Signed "ad hoc" (locally, no Apple account): Apple Silicon requires a
# signature to run at all. Hardened runtime on, as notarization will need.
codesign --force --sign - --options runtime "$APP"

# without extended attributes: they'd be stored as "._" files, which break the
# app's signature if the zip is opened by anything but Finder
(cd build && rm -f Siftr.zip && ditto -c -k --norsrc --noextattr --keepParent Siftr.app Siftr.zip)

echo
echo "Done: $APP  ($(du -sh "$APP" | cut -f1) on disk; build/Siftr.zip to share)"
lipo -archs "$APP/Contents/MacOS/Siftr" | sed 's/^/Runs natively on: /'
