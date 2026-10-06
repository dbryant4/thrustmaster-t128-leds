#!/bin/sh
# Builds dist/thrustmaster-t128-leds-<version>-windows.zip: everything a user installs.
# Needs mingw-w64, a host C compiler, lua and zip (see README.md).
set -eu
cd "$(dirname "$0")/.."

version=$(sed -n 's/^#define VERSION "\([0-9.]*\)"/\1/p' bridge/fs25_t128_leds.c)
[ -n "$version" ] || { echo "could not read the version from bridge/fs25_t128_leds.c" >&2; exit 1; }

# The mod carries the same version in FS25's four-part form (0.1.0 -> 0.1.0.0), in two places.
mod_desc=$(sed -n 's|.*<version>\(.*\)</version>.*|\1|p' fs-mod/FS25_T128Telemetry/modDesc.xml)
mod_lua=$(sed -n 's/^T128Telemetry.VERSION = "\([0-9.]*\)".*/\1/p' fs-mod/FS25_T128Telemetry/T128Telemetry.lua)
if [ "$mod_desc" != "$version.0" ] || [ "$mod_lua" != "$version.0" ]; then
    echo "version mismatch: bridge $version, modDesc.xml $mod_desc, T128Telemetry.lua $mod_lua (both should be $version.0)" >&2
    exit 1
fi

mkdir -p bridge/build
cc -Wall -Wextra -O2 bridge/test_logic.c -o bridge/build/test_logic
bridge/build/test_logic | tail -n 1
x86_64-w64-mingw32-gcc -O2 -static -Wall -Wextra bridge/fs25_t128_leds.c -o bridge/build/fs25_t128_leds.exe -lhid -lsetupapi
(cd fs-mod && ./package.sh >/dev/null)

name="thrustmaster-t128-leds-$version-windows"
stage="dist/$name"
rm -rf "$stage" "dist/$name.zip"
mkdir -p "$stage"
cp bridge/build/fs25_t128_leds.exe "bridge/windows/Start T128 LEDs.bat" fs-mod/dist/FS25_T128Telemetry.zip "$stage/"
cp docs/INSTALL.md "$stage/INSTALL.md"
cp LICENSE "$stage/LICENSE.txt"
(cd dist && zip -q -r "$name.zip" "$name")
rm -rf "$stage"

echo "built dist/$name.zip:"
unzip -l "dist/$name.zip"
