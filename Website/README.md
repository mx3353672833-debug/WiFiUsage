# WiFiUsage Website

Static download website for `https://xjp.one/wifiusage/`.

## Local preview

The page uses root-relative production paths. Preview from this repository root with a temporary `wifiusage` symlink:

```sh
cd path/to/WiFiUsage
ln -sfn Website wifiusage
python3 -m http.server 4173
```

Open `http://127.0.0.1:4173/wifiusage/`. Remove the symlink after preview if it is not needed.

Shared xjp.one navigation files are unavailable in this local server unless copied or proxied. The core page and download stay functional without them.

## Asset sources

- `assets/app-icon.png` ← `../Config/Assets.xcassets/AppIcon.appiconset/AppIcon-512@2x.png`
- Release: `1.1.0` (build `2`)
- `downloads/WiFiUsage-1.1.0-free.dmg` ← `dist/WiFiUsage-1.1.0-public-free.dmg`
- Final size: `2406265` bytes (`2.4 MB`)
- Final SHA-256: `aad32b364b5418948b34570adf1fd6cfadd874a740eb6d0b53d8aa2a0ab031b5`

`downloads/` is deployment material. The root `.gitignore` ignores all `*.dmg`, so the binary is not committed.

## Release verification

Run immediately before deployment:

```sh
PROJECT_ROOT=$(pwd -P)
DMG="$PROJECT_ROOT/dist/WiFiUsage-1.1.0-public-free.dmg"
APP="$PROJECT_ROOT/dist/PublicRelease/WiFiUsage.app"

hdiutil verify "$DMG"
shasum -a 256 "$DMG"
file "$APP/Contents/MacOS/WiFiUsage"
bash Scripts/verify-public-artifact.sh PublicRelease "$DMG"
bash Scripts/scan-website-release.sh Website "$DMG"
```

Before deployment, replace all three release-metadata placeholders with values from the final DMG. Update `index.html`, `brand-spec.md`, root `README.md`, and release notes if any version, build, size, architecture, installation guidance, checksum, diagnostic behavior, or feedback privacy boundary changes.

## Deployment allowlist

Publish only these entries from `Website/` to the public `/wifiusage/` route:

- `index.html`
- `script.js`
- `styles.css`
- `assets/`
- `downloads/`

Explicitly exclude all `*.md` files, including this README and `brand-spec.md`. Do not publish any other repository file, hidden file, build output, configuration, or source code. Verify the allowlisted copy and final DMG checksum before switching the public release.

The website form and macOS app send feedback through the product's public HTTPS feedback endpoint. Feedback-service components and configuration are not part of this static-site deployment.

The macOS app keeps desensitized diagnostic logs locally for up to 7 days and 5 MiB, with no automatic upload. Every in-app feedback submission sends the problem description, software version and build, macOS version, and architecture. Contact details and the desensitized diagnostic attachment are separate explicit choices; the attachment is previewable before sending. Traffic, plan, and settings data remain local.

## Rollback

Keep a recoverable copy of the previously published allowlisted files. If verification fails, restore that known-good static bundle and recheck the public page and download before continuing.
