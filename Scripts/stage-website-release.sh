#!/usr/bin/env bash
set -euo pipefail

usage() { printf 'Usage: %s [dmg-path]\n' "$(basename "$0")" >&2; exit 64; }
fail() { printf 'error: %s\n' "$*" >&2; exit 1; }

[[ $# -le 1 ]] || usage
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)
PROJECT_ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd -P)
DIST_ROOT="$PROJECT_ROOT/dist"
SOURCE_ROOT="$PROJECT_ROOT/Website"
DMG=${1:-"$DIST_ROOT/WiFiUsage-1.1.0-public-free.dmg"}
STAGE_ROOT="$DIST_ROOT/website-release"

[[ -f "$DMG" ]] || fail "DMG not found: $DMG"
for item in index.html script.js styles.css; do
  [[ -f "$SOURCE_ROOT/$item" ]] || fail "website file not found: $item"
done
[[ -d "$SOURCE_ROOT/assets" ]] || fail 'website assets directory not found'
[[ ! -L "$STAGE_ROOT" ]] || fail "refusing symlinked stage path: $STAGE_ROOT"
mkdir -p "$DIST_ROOT"
DIST_REAL=$(CDPATH= cd -- "$DIST_ROOT" && pwd -P)
[[ "$DIST_REAL" == "$PROJECT_ROOT/dist" ]] || fail 'dist resolves outside the project'

if LC_ALL=C grep -R -n '__FINAL_' \
  "$SOURCE_ROOT/index.html" "$SOURCE_ROOT/script.js" "$SOURCE_ROOT/styles.css" >/dev/null; then
  fail 'website still contains unreplaced release placeholders'
fi

rm -rf -- "$STAGE_ROOT"
mkdir -p "$STAGE_ROOT/assets" "$STAGE_ROOT/downloads"
cp -p "$SOURCE_ROOT/index.html" "$SOURCE_ROOT/script.js" "$SOURCE_ROOT/styles.css" "$STAGE_ROOT/"
cp -Rp "$SOURCE_ROOT/assets/." "$STAGE_ROOT/assets/"
cp -p "$DMG" "$STAGE_ROOT/downloads/WiFiUsage-1.1.0-free.dmg"

actual=$(find "$STAGE_ROOT" -mindepth 1 -maxdepth 1 -exec basename {} \; | LC_ALL=C sort)
expected=$(printf '%s\n' assets downloads index.html script.js styles.css | LC_ALL=C sort)
[[ "$actual" == "$expected" ]] || fail 'website stage contains files outside the public allowlist'
if find "$STAGE_ROOT" -type f \( -iname '*.md' -o -iname '*.txt' \) -print -quit | grep -q .; then
  fail 'website stage contains documentation files'
fi

printf 'Staged website release: %s\n' "$STAGE_ROOT"
