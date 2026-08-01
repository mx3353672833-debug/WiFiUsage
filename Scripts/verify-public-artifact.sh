#!/usr/bin/env bash
set -euo pipefail

usage() { printf 'Usage: %s PublicTest|PublicRelease [artifact-path]\n' "$(basename "$0")" >&2; exit 64; }
fail() { printf 'verification failed: %s\n' "$*" >&2; exit 1; }

[[ $# -ge 1 && $# -le 2 ]] || usage
VARIANT=$1
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)
PROJECT_ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd -P)
case "$VARIANT" in
  PublicTest)
    EXPECTED_BUNDLE_ID='one.xjp.WiFiUsage.PublicTest'
    EXPECTED_APP_NAME='WiFiUsage Public Test.app'
    EXPECTED_SUPPORT_DIR='WiFiUsage-PublicTest'
    DEFAULT_ARTIFACT="$PROJECT_ROOT/dist/PublicTest/$EXPECTED_APP_NAME"
    ;;
  PublicRelease)
    EXPECTED_BUNDLE_ID='one.xjp.WiFiUsage'
    EXPECTED_APP_NAME='WiFiUsage.app'
    EXPECTED_SUPPORT_DIR='WiFiUsage'
    DEFAULT_ARTIFACT="$PROJECT_ROOT/dist/WiFiUsage-1.0-public-free.dmg"
    ;;
  *) usage ;;
esac
ARTIFACT=${2:-$DEFAULT_ARTIFACT}

[[ $(uname -s) == Darwin ]] || fail 'this script must run on macOS'
for tool in codesign lipo plutil file find hdiutil diff cmp; do
  command -v "$tool" >/dev/null 2>&1 || fail "required tool not found: $tool"
done

TMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/wifiusage-verify.XXXXXX")
MOUNT_POINT=
cleanup() {
  if [[ -n "$MOUNT_POINT" && -d "$MOUNT_POINT" ]]; then
    hdiutil detach "$MOUNT_POINT" -quiet >/dev/null 2>&1 || true
  fi
  rm -rf -- "$TMP_DIR"
}
trap cleanup EXIT HUP INT TERM

check_forbidden_files() {
  local root=$1 found
  found=$(find "$root" -type f \( \
    -iname '*.entitlements' -o -iname 'embedded.provisionprofile' -o \
    -iname '*.mobileprovision' -o -iname '*.provisionprofile' -o \
    -iname '*.cer' -o -iname '*.crt' -o -iname '*.der' -o \
    -iname '*.pem' -o -iname '*.p12' -o -iname '*.pfx' -o -iname '*.key' \
  \) -print)
  [[ -z "$found" ]] || fail "forbidden entitlement, provisioning, or certificate file: $found"
}

check_plists_for_location() {
  local root=$1 plist xml="$TMP_DIR/plist.xml"
  while IFS= read -r -d '' plist; do
    if plutil -convert xml1 -o "$xml" "$plist" >/dev/null 2>&1 && \
      LC_ALL=C grep -Eaiq 'NSLocation|location.*usage.*description|com\.apple\.security\.personal-information\.location' "$xml"; then
      fail "location permission metadata found: $plist"
    fi
  done < <(find "$root" -type f \( -name '*.plist' -o -name 'Info.plist' \) -print0)
}

check_signature() {
  local item=$1 label=$2 arch details entitlements entitlement_xml
  codesign --verify --all-architectures --strict --verbose=4 "$item" >/dev/null 2>&1 || fail "code signature verification failed: $label"

  for arch in arm64 x86_64; do
    details="$TMP_DIR/codesign-details-$arch.txt"
    codesign -d --arch "$arch" --verbose=4 "$item" >"$details" 2>&1 || fail "cannot inspect $arch code signature: $label"
    LC_ALL=C grep -q '^Signature=adhoc$' "$details" || fail "$arch signature is not ad-hoc: $label"
    ! LC_ALL=C grep -q '^Authority=' "$details" || fail "$arch signature contains an Authority: $label"
    LC_ALL=C grep -q '^TeamIdentifier=not set$' "$details" || fail "$arch TeamIdentifier is set or not reported as unset: $label"

    entitlements="$TMP_DIR/entitlements-$arch.plist"
    entitlement_xml="$TMP_DIR/entitlements-$arch.xml"
    rm -f "$entitlements" "$entitlement_xml"
    if codesign -d --arch "$arch" --entitlements "$entitlements" "$item" >/dev/null 2>&1 && [[ -s "$entitlements" ]]; then
      plutil -convert xml1 -o "$entitlement_xml" "$entitlements" >/dev/null 2>&1 || fail "cannot parse $arch signed entitlements: $label"
      if ! tr -d '[:space:]' <"$entitlement_xml" | LC_ALL=C grep -q '<dict></dict>'; then
        fail "$arch signed entitlements are present: $label"
      fi
    fi
  done
}

check_app() {
  local app=$1 info bundle_id distribution_variant support_directory allows_location allows_import
  [[ -d "$app" ]] || fail "app not found: $app"
  [[ $(basename "$app") == "$EXPECTED_APP_NAME" ]] || fail "unexpected app name: $(basename "$app")"
  info="$app/Contents/Info.plist"
  [[ -f "$info" ]] || fail 'Contents/Info.plist is missing'

  bundle_id=$(plutil -extract CFBundleIdentifier raw -o - "$info" 2>/dev/null) || fail 'cannot read CFBundleIdentifier'
  distribution_variant=$(plutil -extract WUDistributionVariant raw -o - "$info" 2>/dev/null) || fail 'cannot read WUDistributionVariant'
  support_directory=$(plutil -extract WUApplicationSupportDirectory raw -o - "$info" 2>/dev/null) || fail 'cannot read WUApplicationSupportDirectory'
  allows_location=$(plutil -extract WUAllowsLocationSSIDAccess raw -o - "$info" 2>/dev/null) || fail 'cannot read WUAllowsLocationSSIDAccess'
  allows_import=$(plutil -extract WUAllowsLegacyDatabaseImport raw -o - "$info" 2>/dev/null) || fail 'cannot read WUAllowsLegacyDatabaseImport'
  [[ "$bundle_id" == "$EXPECTED_BUNDLE_ID" ]] || fail "bundle ID is $bundle_id, expected $EXPECTED_BUNDLE_ID"
  [[ "$distribution_variant" == "$VARIANT" ]] || fail "runtime variant is $distribution_variant, expected $VARIANT"
  [[ "$support_directory" == "$EXPECTED_SUPPORT_DIR" ]] || fail 'Application Support directory is incorrect'
  [[ "$allows_location" == false ]] || fail 'location SSID access is enabled'
  [[ "$allows_import" == false ]] || fail 'legacy database import is enabled'

  codesign --verify --deep --all-architectures --strict --verbose=4 "$app" >/dev/null 2>&1 || fail 'deep code signature verification failed'
  check_signature "$app" "$app"

  check_forbidden_files "$app"
  check_plists_for_location "$app"

  local macho_count=0 binary archs sorted
  while IFS= read -r -d '' binary; do
    if file -b "$binary" | LC_ALL=C grep -q 'Mach-O'; then
      macho_count=$((macho_count + 1))
      archs=$(lipo -archs "$binary" 2>/dev/null) || fail "cannot inspect architectures: $binary"
      sorted=$(printf '%s\n' $archs | LC_ALL=C sort | tr '\n' ' ')
      [[ "$sorted" == 'arm64 x86_64 ' ]] || fail "architectures are not exactly arm64+x86_64: $binary"
      check_signature "$binary" "$binary"
    fi
  done < <(find "$app" -type f -print0)
  [[ $macho_count -gt 0 ]] || fail 'no Mach-O executable found in app'
}

verify_dmg() {
  local dmg=$1 attach_plist="$TMP_DIR/attach.plist" index candidate contents expected staged_app
  [[ -f "$dmg" ]] || fail "DMG not found: $dmg"
  [[ $(basename "$dmg") == 'WiFiUsage-1.0-public-free.dmg' ]] || fail 'unexpected DMG filename'
  hdiutil verify "$dmg" >/dev/null || fail 'DMG integrity verification failed'
  hdiutil attach -readonly -nobrowse -plist "$dmg" >"$attach_plist" || fail 'cannot mount DMG'
  for index in {0..15}; do
    candidate=$(/usr/libexec/PlistBuddy -c "Print :system-entities:$index:mount-point" "$attach_plist" 2>/dev/null || true)
    if [[ -n "$candidate" ]]; then MOUNT_POINT=$candidate; break; fi
  done
  [[ -n "$MOUNT_POINT" && -d "$MOUNT_POINT" ]] || fail 'cannot determine DMG mount point'

  contents=$(find "$MOUNT_POINT" -mindepth 1 -maxdepth 1 -exec basename {} \; | LC_ALL=C sort)
  expected=$(printf '%s\n' 'Applications' 'WiFiUsage.app' '安装说明.txt' | LC_ALL=C sort)
  [[ "$contents" == "$expected" ]] || fail 'DMG top-level contents are not exact'
  [[ -L "$MOUNT_POINT/Applications" ]] || fail 'Applications item is not a symbolic link'
  [[ $(readlink "$MOUNT_POINT/Applications") == /Applications ]] || fail 'Applications link target is not /Applications'
  [[ -f "$MOUNT_POINT/安装说明.txt" ]] || fail 'installer instructions are missing'
  cmp -s "$PROJECT_ROOT/Packaging/Public/安装说明.txt" "$MOUNT_POINT/安装说明.txt" || fail 'installer instructions differ from the approved copy'
  check_forbidden_files "$MOUNT_POINT"
  check_app "$MOUNT_POINT/WiFiUsage.app"

  staged_app="$PROJECT_ROOT/dist/PublicRelease/WiFiUsage.app"
  if [[ -d "$staged_app" ]]; then
    diff -qr "$staged_app" "$MOUNT_POINT/WiFiUsage.app" >/dev/null || fail 'mounted app differs from staged app'
  fi
}

case "$ARTIFACT" in
  *.dmg)
    [[ "$VARIANT" == PublicRelease ]] || fail 'PublicTest must be verified as an app, not a DMG'
    verify_dmg "$ARTIFACT" ;;
  *.app) check_app "$ARTIFACT" ;;
  *) fail 'artifact must be an .app or .dmg' ;;
esac
printf 'Verified %s artifact: %s\n' "$VARIANT" "$ARTIFACT"
