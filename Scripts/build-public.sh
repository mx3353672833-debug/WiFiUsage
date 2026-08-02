#!/usr/bin/env bash
set -euo pipefail

usage() { printf 'Usage: %s PublicTest|PublicRelease\n' "$(basename "$0")" >&2; exit 64; }
fail() { printf 'error: %s\n' "$*" >&2; exit 1; }

[[ $# -eq 1 ]] || usage
VARIANT=$1
case "$VARIANT" in
  PublicTest)
    APP_NAME='WiFiUsage Public Test.app'
    BUILD_OVERRIDES=(WRAPPER_NAME="$APP_NAME")
    ;;
  PublicRelease)
    APP_NAME='WiFiUsage.app'
    BUILD_OVERRIDES=()
    ;;
  *) usage ;;
esac

[[ $(uname -s) == Darwin ]] || fail 'this script must run on macOS'
for tool in xcodegen xcodebuild ditto lipo codesign hdiutil plutil; do
  command -v "$tool" >/dev/null 2>&1 || fail "required tool not found: $tool"
done

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)
PROJECT_ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd -P)
DIST_ROOT="$PROJECT_ROOT/dist"
WORK_ROOT="$DIST_ROOT/.public-build/$VARIANT"
DERIVED_DATA="$WORK_ROOT/DerivedData"
STAGE_ROOT="$WORK_ROOT/stage"
OUTPUT_DIR="$DIST_ROOT/$VARIANT"
OUTPUT_APP="$OUTPUT_DIR/$APP_NAME"
INSTRUCTIONS="$PROJECT_ROOT/Packaging/Public/安装说明.txt"
DMG_PATH="$DIST_ROOT/WiFiUsage-1.1.0-public-free.dmg"

assert_safe_path() {
  local path=$1
  case "$path" in
    /Applications|/Applications/*)
      fail "refusing path under /Applications: $path" ;;
    "$HOME/Library/Application Support/WiFiUsage"|"$HOME/Library/Application Support/WiFiUsage"/*)
      fail "refusing production Application Support path: $path" ;;
    /Library/Application\ Support/WiFiUsage|/Library/Application\ Support/WiFiUsage/*)
      fail "refusing production Application Support path: $path" ;;
  esac
}

for path in "$PROJECT_ROOT" "$DIST_ROOT" "$WORK_ROOT" "$DERIVED_DATA" "$STAGE_ROOT" "$OUTPUT_DIR" "$OUTPUT_APP" "$DMG_PATH"; do
  assert_safe_path "$path"
done
[[ -f "$PROJECT_ROOT/project.yml" ]] || fail 'project.yml not found'
[[ -f "$INSTRUCTIONS" ]] || fail "installer instructions not found: $INSTRUCTIONS"

mkdir -p "$DIST_ROOT"
DIST_REAL=$(CDPATH= cd -- "$DIST_ROOT" && pwd -P)
assert_safe_path "$DIST_REAL"
[[ "$DIST_REAL" == "$PROJECT_ROOT/dist" ]] || fail "dist resolves outside the project: $DIST_REAL"

# Refuse symlinked deletion boundaries before removing generated paths.
for path in "$DIST_ROOT/.public-build" "$WORK_ROOT" "$OUTPUT_DIR"; do
  [[ ! -L "$path" ]] || fail "refusing symlinked generated path: $path"
done

# Delete only generated paths beneath the verified project dist directory.
rm -rf -- "$WORK_ROOT" "$OUTPUT_DIR"
mkdir -p "$DERIVED_DATA" "$STAGE_ROOT" "$OUTPUT_DIR"
if [[ "$VARIANT" == PublicRelease ]]; then
  rm -f -- "$DMG_PATH"
fi

printf 'Generating Xcode project...\n'
xcodegen generate --spec "$PROJECT_ROOT/project.yml" --project "$PROJECT_ROOT"

COMMON_XCODE_ARGS=(
  -project "$PROJECT_ROOT/WiFiUsage.xcodeproj"
  -scheme "$VARIANT"
  -configuration "$VARIANT"
  -derivedDataPath "$DERIVED_DATA"
  -jobs 1
  CODE_SIGNING_ALLOWED=NO
  CODE_SIGNING_REQUIRED=NO
  CODE_SIGN_IDENTITY=
  DEVELOPMENT_TEAM=
  COMPILER_INDEX_STORE_ENABLE=NO
  SWIFT_ENABLE_BATCH_MODE=NO
)

printf 'Running low-memory tests for %s...\n' "$VARIANT"
xcodebuild "${COMMON_XCODE_ARGS[@]}" \
  -destination 'platform=macOS' \
  -parallel-testing-enabled NO \
  -maximum-parallel-testing-workers 1 \
  ONLY_ACTIVE_ARCH=YES \
  test

printf 'Building unsigned universal app for %s...\n' "$VARIANT"
if [[ ${#BUILD_OVERRIDES[@]} -gt 0 ]]; then
  xcodebuild "${COMMON_XCODE_ARGS[@]}" \
    -destination 'generic/platform=macOS' \
    ARCHS='arm64 x86_64' \
    ONLY_ACTIVE_ARCH=NO \
    "${BUILD_OVERRIDES[@]}" \
    build
else
  xcodebuild "${COMMON_XCODE_ARGS[@]}" \
    -destination 'generic/platform=macOS' \
    ARCHS='arm64 x86_64' \
    ONLY_ACTIVE_ARCH=NO \
    build
fi

BUILT_APP="$DERIVED_DATA/Build/Products/$VARIANT/$APP_NAME"
[[ -d "$BUILT_APP" ]] || fail "built app not found: $BUILT_APP"
INFO_PLIST="$BUILT_APP/Contents/Info.plist"
[[ -f "$INFO_PLIST" ]] || fail "built Info.plist not found: $INFO_PLIST"
EXECUTABLE_NAME=$(plutil -extract CFBundleExecutable raw -o - "$INFO_PLIST")
BUILT_EXECUTABLE="$BUILT_APP/Contents/MacOS/$EXECUTABLE_NAME"
[[ -f "$BUILT_EXECUTABLE" ]] || fail "built executable not found: $BUILT_EXECUTABLE"
# Test action can leave hosted test bundles and XCTest runtime inside the app product. Never ship them.
rm -rf -- "$BUILT_APP/Contents/PlugIns" "$BUILT_APP/Contents/Frameworks"
ARCHS=$(lipo -archs "$BUILT_EXECUTABLE" | tr ' ' '\n' | LC_ALL=C sort | tr '\n' ' ')
[[ "$ARCHS" == 'arm64 x86_64 ' ]] || fail 'built executable is not exactly arm64+x86_64'

printf 'Staging app...\n'
ditto "$BUILT_APP" "$OUTPUT_APP"

# Replace any linker-generated signature with the final canonical ad-hoc signature.
codesign --force --deep --sign - --timestamp=none --options runtime "$OUTPUT_APP"
codesign --verify --deep --strict --verbose=2 "$OUTPUT_APP"

if [[ "$VARIANT" == PublicRelease ]]; then
  DMG_STAGE="$STAGE_ROOT/dmg"
  mkdir -p "$DMG_STAGE"
  ditto "$OUTPUT_APP" "$DMG_STAGE/WiFiUsage.app"
  cp -p "$INSTRUCTIONS" "$DMG_STAGE/安装说明.txt"
  ln -s /Applications "$DMG_STAGE/Applications"

  printf 'Creating %s...\n' "$(basename "$DMG_PATH")"
  hdiutil create -volname 'WiFiUsage 1.1.0 Public Free' -srcfolder "$DMG_STAGE" -format UDZO -ov "$DMG_PATH"
fi

printf 'Built app: %s\n' "$OUTPUT_APP"
if [[ "$VARIANT" == PublicRelease ]]; then
  printf 'Built DMG: %s\n' "$DMG_PATH"
fi
