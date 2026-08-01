# WiFiUsage Website Brand Spec

## Product facts

- Display name: 流量账本
- Technical name: WiFiUsage
- Version: 1.0 (build 1)
- Bundle ID: `one.xjp.WiFiUsage`
- Platform: macOS 14 or later
- Architectures: Universal binary (`arm64` + `x86_64`)
- Price: free
- Website: `https://xjp.one/wifiusage/`
- Source: repository root

## Distribution

- File: `WiFiUsage-1.0-free.dmg`
- Size: 2,108,552 bytes (display as 2.1 MB)
- SHA-256: `86e6140c01029c81dbd5699b9b57ba3f9b6af20e38aab0c3da6936ed13e366e2`
- `hdiutil verify`: valid
- Signature: anonymous ad-hoc (`Signature=adhoc`, `TeamIdentifier=not set`)
- Hardened runtime: enabled
- Notarization: no stapled ticket; website must explain first-launch right-click Open flow

Recalculate file size and SHA-256 before every deployment. Website, release notes, and server copy must match final artifact.

## Real assets

- App icon source: `../Config/Assets.xcassets/AppIcon.appiconset/AppIcon-512@2x.png`
- Website icon copy: `assets/app-icon.png`
- Product screenshot source: `../docs/images/overview.jpg`
- Website screenshot copy: `assets/overview.jpg`
- Do not redraw product UI or replace screenshot with generated imagery.

## Product capabilities

- Physical Wi-Fi download, upload, and total counters
- Separate history by Wi-Fi name
- Today, 24-hour, 7-day, current-month, and current-year views
- Local per-application approximation using macOS `nettop`
- Low-energy and temporary precise sampling modes
- Plan quota and cost estimation
- Menu bar summary
- User-level launch at login
- Local SQLite storage with a default 400-day retention window

## Privacy facts

- No account
- No administrator permission
- No driver, Network Extension, or System Extension
- No telemetry, advertising, cloud sync, or remote upload
- Database: `~/Library/Application Support/WiFiUsage/usage.sqlite`
- The public build identifies the current Wi-Fi from the local network summary without requesting location permission; geographic location is not read, saved, or uploaded

## Required limitations

- Only traffic generated while WiFiUsage is running can be recorded.
- Same-name SSIDs are treated as one Wi-Fi.
- Physical interface totals are the primary measurement.
- Per-application values are local approximations.
- Short-lived connections, system services, VPNs, and proxies may not be fully assigned.
- Application rankings currently combine all Wi-Fi networks.
- Multiple currencies are not automatically converted.
- Cost estimates do not replace carrier bills or audit records.

## Voice

Precise, calm, transparent. Short Chinese sentences. Explain measurement boundaries directly.

Allowed:
- 物理 Wi-Fi 总用量
- 应用用量估算
- 套餐费用估算
- 数据仅保存在本机
- 免费
- 无需账号

Forbidden:
- 100% 精准
- 捕获所有流量
- 实时监控所有应用
- 绝不漏记
- 与运营商账单完全一致
- 银行级安全
- 零性能影响
- Fabricated user counts, download counts, ratings, testimonials, awards, or media logos

## Design system

Direction: macOS network instrument — editorial light layout with one dark live-traffic instrument in the hero.

- Paper: `#F3F6F7`
- Paper deep: `#E8EDEF`
- Ink: `#101417`
- Secondary ink: `#4F5B61`
- Download: `#1FC7A5`
- Upload: `#8175F6`
- Cost: `#B67C28`
- Instrument: `#13171C`
- Display: Songti SC / STSong for editorial Chinese headlines
- Body: Apple SF / PingFang SC
- Utility: SF Mono / Menlo
- Motion: one coordinated hero instrument sequence plus restrained section reveals and a scroll-progress signal; never animate every small control independently
- Signature: animated circular upload/download meter derived from the app's traffic language

Avoid generic SaaS feature-card walls, decorative numbering, hero screenshots, bright gradients, colored glow, stock photos, emoji decoration, and fake product imagery.
