# 流量账本 v1.0.0

这是流量账本的首个公开版本。一款完全在本机运行的 macOS Wi‑Fi 流量统计工具，无需账号、管理员权限或额外系统扩展。

## 主要功能

- 分别统计不同 Wi‑Fi 的下载、上传和总用量。
- 连接切换后自动跟随当前 Wi‑Fi。
- 为每个 Wi‑Fi 独立绑定计费套餐。
- 根据基础费用、流量额度和超额单价估算费用。
- 查看今日、24 小时、7 天、本月和今年的趋势。
- 在本机估算各应用的 Wi‑Fi 用量。
- 提供低耗能和临时精细统计两种模式。
- 通过菜单栏快速查看用量。
- 支持登录时自动启动。
- 所有数据仅保存在本机。

## 系统要求

- macOS 14 或更高版本
- Apple Silicon Mac 或 Intel Mac

## 下载与安装

从官网下载 Universal DMG，支持 Apple Silicon 和 Intel Mac：

- 官网：<https://xjp.one/wifiusage/>
- DMG：<https://xjp.one/wifiusage/downloads/WiFiUsage-1.0-free.dmg>

```text
文件：WiFiUsage-1.0-free.dmg
SHA-256：86e6140c01029c81dbd5699b9b57ba3f9b6af20e38aab0c3da6936ed13e366e2
```

1. 打开 DMG，将 `WiFiUsage.app` 拖入“应用程序”。
2. 当前版本使用不包含开发者身份的匿名 ad-hoc 签名，尚未经过 Apple 公证。如果 macOS 首次阻止启动，请在“应用程序”中右键 WiFiUsage，选择“打开”；若仍被阻止，再到“系统设置”→“隐私与安全性”点“仍要打开”。
3. 打开后会自动识别当前 Wi‑Fi，无需授予定位权限。

也可以下载本 Release 的 Source code（ZIP 或 TAR.GZ），按照仓库 README 从源码构建。

Wi‑Fi 名称权限不会被用于读取、保存或上传地理位置。

## 已知限制

- 仅记录应用运行期间的流量。
- 同名 SSID 会合并为同一个 Wi‑Fi。
- 应用流量属于本地估算，短连接、VPN、代理和系统服务可能无法完整识别。
- 应用排行暂不支持按 Wi‑Fi 拆分。
- 套餐费用仅供参考，不代表运营商账单。
- 当前 DMG 尚未经过 Apple 公证，首次打开可能需要右键应用并选择“打开”。
