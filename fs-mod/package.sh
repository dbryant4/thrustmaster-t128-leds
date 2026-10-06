#!/usr/bin/env bash
# Build fs-mod/dist/FS25_T128Telemetry.zip in the layout Farming Simulator 25
# expects: modDesc.xml and the other files at the root of the zip, not inside
# a folder. Copy the zip, unchanged and without renaming it, into
#   Documents\My Games\FarmingSimulator2025\mods\
#
#   ./package.sh             syntax check, run the mock test, build the zip
#   ./package.sh --no-test   skip the checks (when Lua is not installed)
set -euo pipefail

cd "$(dirname "$0")"

MOD=FS25_T128Telemetry
OUT="dist/$MOD.zip"

if [[ "${1:-}" != "--no-test" ]]; then
    if command -v luac >/dev/null 2>&1; then
        luac -p "$MOD"/*.lua tests/*.lua
        echo "luac -p: ok"
    else
        echo "luac not found, skipping the syntax check"
    fi
    if command -v lua >/dev/null 2>&1; then
        tmp="$(mktemp -d)"
        lua tests/run_mock.lua "$tmp" | tail -n 1
        rm -rf "$tmp"
    else
        echo "lua not found, skipping the mock test"
    fi
fi

for required in modDesc.xml icon_T128Telemetry.dds T128Telemetry.lua; do
    [[ -f "$MOD/$required" ]] || { echo "missing $MOD/$required" >&2; exit 1; }
done

mkdir -p dist
rm -f "$OUT"
# -X: no extra file attributes, -D: no directory entries; hidden files stay out
(cd "$MOD" && zip -q -r -X -D -9 "../$OUT" . -x '.*' -x '*/.*')

# modDesc.xml has to be at the root of the archive
listing="$(unzip -Z1 "$OUT")"
grep -qx 'modDesc.xml' <<<"$listing" || { echo "modDesc.xml is not at the zip root" >&2; exit 1; }

echo "built $OUT:"
unzip -l "$OUT"
