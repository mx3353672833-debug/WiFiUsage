# WiFiUsage Website Brand Spec

## Product facts

- Display name: 流量账本
- Technical name: WiFiUsage
- Version: 1.1.0 (build 2)
- Platform: macOS 14 or later
- Architectures: Universal binary (`arm64` + `x86_64`)
- Price: free
- Website: `https://xjp.one/wifiusage/`

## Distribution

- File: `WiFiUsage-1.1.0-free.dmg`
- Size: `2406265` bytes (display as `2.4 MB`)
- SHA-256: `aad32b364b5418948b34570adf1fd6cfadd874a740eb6d0b53d8aa2a0ab031b5`
- Integrity must be verified against the final public artifact before deployment

Recalculate file size and SHA-256 before every deployment. Website, release notes, and public download copy must match the final artifact.

## Visual assets

- Use the current shipping app icon.
- Do not add real screenshots, stock photography, or fabricated product imagery.

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
- Local desensitized diagnostic logs, retained for up to 7 days and capped at 5 MiB
- In-app feedback with a previewable, separately selected diagnostic attachment

## Privacy facts

- No account
- No administrator permission
- No driver, Network Extension, or System Extension
- No automatic telemetry, advertising, or cloud sync
- Traffic, plan, and settings data remain local
- Diagnostic logs remain local unless the user explicitly selects an attachment and sends feedback; there is no automatic upload
- Every in-app feedback submission sends the problem description, software version and build, macOS version, and architecture
- Contact details and the desensitized diagnostic attachment are separate explicit choices
- An attached diagnostic report contains feature state and error codes; it excludes Wi-Fi names, application names, file paths, traffic records, plan contents, and contact details
- The local database and diagnostic logs stay in the app's user-scoped data area
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
- 流量、套餐和设置数据仅保存在本机
- 诊断日志不会自动上传
- 联系方式和脱敏诊断日志均由用户分别选择
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
- 所有数据绝不离开本机
- 完全匿名的反馈
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
- Visual motif: animated circular upload/download meter derived from the app's traffic language

Avoid generic SaaS feature-card walls, decorative numbering, hero screenshots, bright gradients, colored glow, stock photos, emoji decoration, and fake product imagery.
