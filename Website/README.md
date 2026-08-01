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
- `downloads/WiFiUsage-1.0-free.dmg` ← `dist/WiFiUsage-1.0-public-free.dmg`

`downloads/` is deployment material. The root `.gitignore` ignores all `*.dmg`, so the binary is not committed.

## Release verification

Run immediately before deployment:

```sh
PROJECT_ROOT=$(pwd -P)
DMG="$PROJECT_ROOT/dist/WiFiUsage-1.0-public-free.dmg"
APP="$PROJECT_ROOT/dist/PublicRelease/WiFiUsage.app"

hdiutil verify "$DMG"
shasum -a 256 "$DMG"
file "$APP/Contents/MacOS/WiFiUsage"
codesign --verify --deep --strict --verbose=2 "$APP"
codesign -dv --verbose=4 "$APP"
bash Scripts/verify-public-artifact.sh PublicRelease "$DMG"
bash Scripts/scan-website-release.sh Website "$DMG"
```

Update `index.html`, `brand-spec.md`, root `README.md`, and release notes if any version, size, architecture, signature, notarization, or checksum value changes.

## Deployment mapping

```text
Website/ → xjp-one/public/wifiusage/
```

Deploy to a timestamped sibling directory first, verify files and DMG checksum, then rename atomically. Exclude `.DS_Store` and `._*` files.

The feedback form posts to the same-origin `POST /api/wifiusage/feedback` endpoint. Its reusable route module is stored at `Deploy/xjp-one/wifiusage-feedback.js`; the live server keeps the private recipient in `WIFIUSAGE_FEEDBACK_TO` and passes its existing mail transporter into `registerWiFiUsageFeedback`. Never put the recipient address or SMTP credentials in `Website/`.

Use the live `xjp-one/public/site-nav.js` as merge base. Add the WiFiUsage link without overwriting newer navigation entries.

Static-only changes do not require DNS changes, Nginx changes, Nginx reload, or an Express restart. Restart the existing Express service only when the feedback route module or its private environment configuration changes.

## Rollback

Keep timestamped backups of:

- the live `xjp-one/public/site-nav.js`
- the live `xjp-one/public/wifiusage/` directory when it already exists

Restore the previous directory and navigation file by atomic rename. If no previous website existed, remove the failed directory to restore the prior 404 state.
