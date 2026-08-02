#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat >&2 <<EOF
Usage: $(basename "$0") [path ...]
With no paths, scans Website and any canonical public DMG.
Findings contain only category and file path, never matched values.
EOF
  exit 64
}
fail() { printf 'error: %s\n' "$*" >&2; exit 1; }

[[ $(uname -s) == Darwin ]] || fail 'this script must run on macOS'
for tool in find file strings grep hdiutil; do
  command -v "$tool" >/dev/null 2>&1 || fail "required tool not found: $tool"
done

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)
PROJECT_ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd -P)
CANONICAL_DMG="$PROJECT_ROOT/dist/WiFiUsage-1.1.0-public-free.dmg"
if [[ $# -eq 0 ]]; then
  TARGETS=("$PROJECT_ROOT/Website")
  [[ -f "$CANONICAL_DMG" ]] && TARGETS+=("$CANONICAL_DMG")
else
  TARGETS=("$@")
fi

TMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/wifiusage-scan.XXXXXX")
MOUNTS_FILE="$TMP_DIR/mounts.txt"
REPORT_FILE="$TMP_DIR/reported.txt"
: >"$MOUNTS_FILE"; : >"$REPORT_FILE"
cleanup() {
  local mount
  while IFS= read -r mount; do
    [[ -n "$mount" ]] && hdiutil detach "$mount" -quiet >/dev/null 2>&1 || true
  done <"$MOUNTS_FILE"
  rm -rf -- "$TMP_DIR"
}
trap cleanup EXIT HUP INT TERM

HIT_COUNT=0
report() {
  local category=$1 path=$2 key
  key="$category"$'\t'"$path"
  if ! grep -Fqx -- "$key" "$REPORT_FILE"; then
    printf '%s\t%s\n' "$category" "$path"
    printf '%s\n' "$key" >>"$REPORT_FILE"
    HIT_COUNT=$((HIT_COUNT + 1))
  fi
}
match_category() {
  local category=$1 pattern=$2 content=$3 path=$4
  if LC_ALL=C grep -Eaiq -- "$pattern" "$content" 2>/dev/null; then report "$category" "$path"; fi
}

scan_content() {
  local content=$1 path=$2
  match_category EMAIL '(^|[^[:alnum:]._%+-])[[:alnum:]._%+-]+@[[:alnum:].-]+\.(com|org|net|edu|gov|io|co|cn|me|dev|app|tech|info|biz|xyz|one)([^[:alnum:]._-]|$)' "$content" "$path"
  match_category TEAM_ID '(TeamIdentifier|team[ _-]?identifier|com\.apple\.developer\.team-identifier|ApplicationIdentifierPrefix)[^A-Z0-9]{0,30}[A-Z0-9]{10}([^A-Z0-9]|$)|(^|[^A-Z0-9])[A-Z0-9]{10}[[:space:]]*([/:_-]?[[:space:]]*(Apple Development|Developer ID|Mac Developer))' "$content" "$path"
  match_category SIGNING_IDENTITY 'Authority[[:space:]]*=|Apple Development([[:space:]:]|$)|Developer ID (Application|Installer)([[:space:]:]|$)|Mac Developer([[:space:]:]|$)|CODE_SIGN_IDENTITY|EXPANDED_CODE_SIGN_IDENTITY|signingCertificate' "$content" "$path"
  match_category DEVELOPMENT_TEAM 'DEVELOPMENT_TEAM[[:space:]]*([=:]|</key>)' "$content" "$path"
  match_category ABSOLUTE_PATH '(^|[^[:alnum:]])(/Users/|/home/|/Volumes/|/www/|file://)' "$content" "$path"
  match_category SSH_SECRET '-----BEGIN ([A-Z0-9 ]+ )?PRIVATE KEY-----|sshpass([[:space:]]|$)|SSHPASS[[:space:]]*=|ssh[_-]?(password|passwd|private[_-]?key)[[:space:]]*[:=]|IdentityFile[[:space:]]+[^[:space:]]+' "$content" "$path"
  match_category CERT_OR_PROVISION 'embedded\.provisionprofile|-----BEGIN (CERTIFICATE|PRIVATE KEY)-----|(^|[^/[:alnum:]_.-])[^/[:space:]]+\.(p12|pfx|mobileprovision|provisionprofile)([^[:alnum:]]|$)' "$content" "$path"
  # Detect executable bypass commands, but not warnings such as "never disable Gatekeeper".
  match_category GATEKEEPER_DISABLE "spctl[[:space:]]+--(master|global)-disable|defaults[[:space:]]+write[[:space:]]+com\\.apple\\.LaunchServices[[:space:]]+LSQuarantine[[:space:]]+-bool[[:space:]]+(false|no)|xattr[[:space:]]+-[a-zA-Z]*c[a-zA-Z]*([[:space:]]|$)|xattr[[:space:]]+(-[a-zA-Z]+[[:space:]]+)*-[a-zA-Z]*d[a-zA-Z]*[[:space:]]+[\"']?com\\.apple\\.quarantine[\"']?|csrutil[[:space:]]+disable" "$content" "$path"
}

scan_name() {
  local path=$1 base
  base=$(basename "$path")
  if printf '%s\n' "$base" | LC_ALL=C grep -Eaiq '\.(entitlements|p12|pfx|cer|crt|der|pem|key|mobileprovision|provisionprofile)$|^embedded\.provisionprofile$'; then
    report CERT_OR_PROVISION "$path"
  fi
}
scan_image_metadata() {
  local path=$1 metadata="$TMP_DIR/image-metadata.txt" filtered="$TMP_DIR/image-metadata-filtered.txt"
  : >"$metadata"; : >"$filtered"
  if command -v exiftool >/dev/null 2>&1; then
    exiftool -a -u -g1 -- "$path" >"$metadata" 2>/dev/null || fail "cannot read image metadata: $path"
  elif command -v mdls >/dev/null 2>&1; then
    mdls "$path" >"$metadata" 2>/dev/null || fail "cannot read image metadata: $path"
  elif command -v sips >/dev/null 2>&1; then
    sips -g all "$path" >"$metadata" 2>/dev/null || fail "cannot read image metadata: $path"
  fi
  # Metadata tools echo their input path; exclude only those tool-generated fields.
  LC_ALL=C grep -Eiv '^[[:space:]]*(Directory|File Name|SourceFile|kMDItemPath|kMDItemFSName)[[:space:]]*[:=]|^/.*$' "$metadata" >"$filtered" || true
  [[ -s "$filtered" ]] && scan_content "$filtered" "$path"
}
scan_file() {
  local path=$1 kind content="$TMP_DIR/content.txt"
  scan_name "$path"
  # CodeResources contains binary hashes and signed resource names. Signature checks
  # validate it separately; arbitrary digest bytes are not meaningful text to scan.
  [[ "$(basename "$path")" == CodeResources ]] && return
  kind=$(file -b -- "$path" 2>/dev/null || true)
  : >"$content"
  case "$kind" in
    *text*|*JSON*|*XML*|*HTML*|*script*|*source*|*plist*|*empty*) cp -- "$path" "$content" 2>/dev/null || fail "cannot read file: $path" ;;
    *) strings -a -- "$path" >"$content" 2>/dev/null || fail "cannot extract binary strings: $path" ;;
  esac
  [[ -s "$content" ]] && scan_content "$content" "$path"
  case "${path##*.}" in
    jpg|JPG|jpeg|JPEG|png|PNG|gif|GIF|tif|TIF|tiff|TIFF|heic|HEIC|webp|WEBP|svg|SVG) scan_image_metadata "$path" ;;
  esac
}
scan_tree() {
  local root=$1 path
  scan_name "$root"
  while IFS= read -r -d '' path; do
    if [[ -f "$path" ]]; then scan_file "$path"; else scan_name "$path"; fi
  done < <(find "$root" -mindepth 1 -print0)
}
scan_dmg() {
  local dmg=$1 attach_plist="$TMP_DIR/attach-$RANDOM.plist" mount_point= candidate index
  scan_file "$dmg"
  hdiutil attach -readonly -nobrowse -plist "$dmg" >"$attach_plist" 2>/dev/null || fail "cannot mount DMG: $dmg"
  for index in {0..15}; do
    candidate=$(/usr/libexec/PlistBuddy -c "Print :system-entities:$index:mount-point" "$attach_plist" 2>/dev/null || true)
    if [[ -n "$candidate" ]]; then mount_point=$candidate; break; fi
  done
  [[ -n "$mount_point" && -d "$mount_point" ]] || fail "cannot determine DMG mount point: $dmg"
  printf '%s\n' "$mount_point" >>"$MOUNTS_FILE"
  scan_tree "$mount_point"
  hdiutil detach "$mount_point" -quiet >/dev/null 2>&1 || fail "cannot detach DMG: $dmg"
  grep -Fvx -- "$mount_point" "$MOUNTS_FILE" >"$MOUNTS_FILE.new" || true
  mv "$MOUNTS_FILE.new" "$MOUNTS_FILE"
}

for target in "${TARGETS[@]}"; do
  [[ -e "$target" ]] || fail "path not found: $target"
  case "$target" in
    *.dmg) scan_dmg "$target" ;;
    *) if [[ -d "$target" ]]; then scan_tree "$target"; else scan_file "$target"; fi ;;
  esac
done

[[ $HIT_COUNT -eq 0 ]] || exit 1
printf 'Scan passed.\n'
