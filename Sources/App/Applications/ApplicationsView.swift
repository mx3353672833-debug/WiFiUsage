import AppKit
import SwiftUI

struct ApplicationsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            PageHeader(title: "应用", subtitle: "查看各应用的 Wi-Fi 用量和费用估算（仅供参考）")
            UsageFilterBar(scope: .applications)

            if !model.repositoryReady {
                EmptyStateCard(
                    symbol: "externaldrive.badge.exclamationmark",
                    title: "本地数据暂不可用",
                    message: "暂时无法读取应用用量，请稍后重试。"
                )
            } else {
                samplingBanner

                if model.applicationRows.isEmpty {
                    EmptyStateCard(
                        symbol: emptyStateSymbol,
                        title: emptyStateTitle,
                        message: emptyStateMessage
                    )
                } else {
                    VStack(alignment: .leading, spacing: 10) {
                        GraphiteCard {
                        Table(model.applicationRows) {
                            TableColumn("应用") { app in
                                HStack(spacing: 9) {
                                    applicationIcon(for: app)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(app.name).fontWeight(.medium)
                                        Text(app.carrierDescription)
                                            .font(.caption2)
                                            .foregroundStyle(.tertiary)
                                    }
                                }
                            }
                            .width(min: 170, ideal: 220)

                            TableColumn("下载") { app in
                                Text(app.bytes.downloadDescription)
                                    .foregroundStyle(Color.usageDownload)
                                    .monospacedDigit()
                            }
                            .width(min: 82, ideal: 92)

                            TableColumn("上传") { app in
                                Text(app.bytes.uploadDescription)
                                    .foregroundStyle(Color.usageUpload)
                                    .monospacedDigit()
                            }
                            .width(min: 82, ideal: 92)

                            TableColumn("累计") { app in
                                Text(app.bytes.totalDescription).monospacedDigit()
                            }
                            .width(min: 82, ideal: 92)

                            TableColumn("比例分摊") { app in
                                Text(app.estimatedCost.map {
                                    "≈" + $0.currencyDescription(code: model.applicationCostCurrencyCode ?? "CNY")
                                } ?? "—")
                                    .foregroundStyle(app.estimatedCost == nil ? Color.secondary : Color.usageCost)
                                    .monospacedDigit()
                                    .help("按已统计应用用量占比分摊 Wi-Fi 套餐费用，不代表运营商账单明细")
                            }
                            .width(min: 92, ideal: 105)
                        }
                        .tableStyle(.inset(alternatesRowBackgrounds: false))
                        .frame(minHeight: hasSamplingBanner ? 285 : 360)
                        }

                        if let unallocated = model.unallocatedApplicationCost, unallocated > 0 {
                            Label(
                                "另有约 \(unallocated.currencyDescription(code: model.applicationCostCurrencyCode ?? "CNY")) 暂未归属到具体应用",
                                systemImage: "info.circle"
                            )
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .padding(24)
    }

    @ViewBuilder
    private var samplingBanner: some View {
        switch model.applicationSamplingState {
        case .stopped:
            statusBanner(
                symbol: "pause.circle.fill",
                color: .secondary,
                title: "应用统计已暂停",
                detail: "已有历史仍可查看；重新开始后继续累计。"
            ) {
                Button("开始应用统计") {
                    Task { await model.startApplicationSampling() }
                }
                .buttonStyle(.borderedProminent)
                .tint(Color.usageDownload)
            }
        case .failed:
            statusBanner(
                symbol: "exclamationmark.triangle.fill",
                color: .orange,
                title: "应用用量读取失败，正在自动重试",
                detail: "Wi-Fi 总用量和费用统计不受影响。"
            ) {
                Button("立即重试") {
                    Task { await model.retryApplicationSampling() }
                }
                .buttonStyle(.borderedProminent)
                .tint(Color.usageDownload)
                .disabled(model.isRetryingApplicationSampling)
                Button("暂停重试") {
                    Task { await model.stopApplicationSampling() }
                }
                .disabled(model.isRetryingApplicationSampling)
            }
        case .starting where model.applicationSamplingMode == .precise:
            statusBanner(
                symbol: "bolt.fill",
                color: .orange,
                title: "正在启动高精度统计",
                detail: preciseModeDetail
            ) {
                Button("取消高精度") {
                    Task { await model.setApplicationSamplingMode(.balanced) }
                }
                .disabled(model.isChangingApplicationSamplingMode)
            }
        case .running where model.applicationSamplingMode == .precise:
            statusBanner(
                symbol: "bolt.fill",
                color: .orange,
                title: "高精度统计正在运行",
                detail: preciseModeDetail
            ) {
                Button("结束高精度") {
                    Task { await model.setApplicationSamplingMode(.balanced) }
                }
            }
        case .starting, .running:
            EmptyView()
        }
    }

    private func statusBanner<Actions: View>(
        symbol: String,
        color: Color,
        title: String,
        detail: String,
        @ViewBuilder actions: () -> Actions
    ) -> some View {
        GraphiteCard {
            HStack(spacing: 12) {
                Image(systemName: symbol)
                    .font(.title3)
                    .foregroundStyle(color)
                    .frame(width: 32)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.headline)
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                Spacer()
                actions()
            }
        }
    }

    private var preciseModeDetail: String {
        if let end = model.preciseSamplingEndsAt {
            return "用于抓取短连接，将在 \(end.formatted(date: .omitted, time: .shortened)) 自动恢复低耗能模式。"
        }
        return "用于抓取短连接，5 分钟后自动恢复低耗能模式。"
    }

    private var hasSamplingBanner: Bool {
        switch model.applicationSamplingState {
        case .stopped, .failed:
            true
        case .starting, .running:
            model.applicationSamplingMode == .precise
        }
    }

    private var emptyStateSymbol: String {
        switch model.applicationSamplingState {
        case .stopped: "pause.circle"
        case .failed: "exclamationmark.triangle"
        case .starting, .running: "app.badge"
        }
    }

    private var emptyStateTitle: String {
        switch model.applicationSamplingState {
        case .stopped: "还没有应用历史"
        case .failed: "暂时没有可显示的应用数据"
        case .starting: "正在启动统计"
        case .running: "正在统计，暂时没有数据"
        }
    }

    private var emptyStateMessage: String {
        switch model.applicationSamplingState {
        case .stopped:
            "开始统计后，会在流量账本运行期间累计各应用的 Wi-Fi 用量。"
        case .failed:
            "可以立即重试或等待后台自动恢复；Wi-Fi 总量统计不受影响。"
        case .starting:
            "正在准备应用用量统计，请稍候。"
        case .running:
            model.applicationSamplingMode == .balanced
                ? "打开网页或使用联网应用后，数据会陆续出现。低耗能模式仅适合观察长期趋势。"
                : "高精度窗口正在运行。打开网页或使用联网应用后，数据会陆续出现。"
        }
    }

    @ViewBuilder
    private func applicationIcon(for app: ApplicationUsageRow) -> some View {
        if let iconPath = app.iconPath {
            Image(nsImage: NSWorkspace.shared.icon(forFile: iconPath))
                .resizable()
                .scaledToFit()
                .frame(width: 26, height: 26)
        } else {
            Image(systemName: "app.fill")
                .foregroundStyle(.secondary)
                .frame(width: 26, height: 26)
        }
    }
}
