import Charts
import SwiftUI

struct DashboardView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack(alignment: .top) {
                    PageHeader(title: "概览", subtitle: "查看 Wi-Fi 流量、趋势与估算费用")
                    Spacer()
                    if let lastUpdated = model.lastUpdated {
                        Text("更新于 \(lastUpdated.formatted(date: .omitted, time: .shortened))")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    } else {
                        Text("尚无用量数据")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                }
                UsageFilterBar()

                HStack(spacing: 14) {
                    MetricTile(
                        title: "下载",
                        value: model.totalUsage.downloadDescription,
                        detail: "当前筛选范围",
                        color: .usageDownload,
                        symbol: "arrow.down"
                    )
                    MetricTile(
                        title: "上传",
                        value: model.totalUsage.uploadDescription,
                        detail: "当前筛选范围",
                        color: .usageUpload,
                        symbol: "arrow.up"
                    )
                    MetricTile(
                        title: "累计流量",
                        value: model.totalUsage.totalDescription,
                        detail: model.selectedNetworkName,
                        color: .white.opacity(0.78),
                        symbol: "sum"
                    )
                    MetricTile(
                        title: model.selectedNetworkKey == nil ? "套餐费用合计" : "估算费用",
                        value: model.estimatedCost?.currencyDescription(
                            code: model.estimatedCostCurrencyCode ?? "CNY"
                        ) ?? "—",
                        detail: model.estimatedCostDetail,
                        color: .usageCost,
                        symbol: "creditcard"
                    )
                }

                GraphiteCard {
                    VStack(alignment: .leading, spacing: 16) {
                        HStack {
                            VStack(alignment: .leading, spacing: 3) {
                                Text("流量趋势").font(.headline)
                                Text("下载与上传的用量变化")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            DirectionLegend(color: .usageDownload, label: "下载")
                            DirectionLegend(color: .usageUpload, label: "上传")
                        }

                        Chart {
                            ForEach(model.chartPoints) { point in
                                LineMark(
                                    x: .value("时间", point.date),
                                    y: .value("下载", point.downloaded)
                                )
                                .foregroundStyle(Color.usageDownload)
                                .lineStyle(StrokeStyle(lineWidth: 2))
                                .interpolationMethod(.catmullRom)

                                AreaMark(
                                    x: .value("时间", point.date),
                                    y: .value("下载", point.downloaded)
                                )
                                .foregroundStyle(
                                    LinearGradient(
                                        colors: [.usageDownload.opacity(0.22), .clear],
                                        startPoint: .top,
                                        endPoint: .bottom
                                    )
                                )
                                .interpolationMethod(.catmullRom)

                                LineMark(
                                    x: .value("时间", point.date),
                                    y: .value("上传", point.uploaded)
                                )
                                .foregroundStyle(Color.usageUpload)
                                .lineStyle(StrokeStyle(lineWidth: 2))
                                .interpolationMethod(.catmullRom)
                            }
                        }
                        .chartYAxis {
                            AxisMarks(position: .leading) { value in
                                AxisGridLine().foregroundStyle(Color.white.opacity(0.06))
                                AxisValueLabel {
                                    if let bytes = value.as(Double.self) {
                                        Text(UInt64(max(0, bytes)).formattedByteCount)
                                    }
                                }
                            }
                        }
                        .chartXAxis {
                            AxisMarks(values: .automatic(desiredCount: 6)) {
                                AxisGridLine().foregroundStyle(Color.white.opacity(0.04))
                                AxisValueLabel(format: .dateTime.month(.abbreviated).day().hour())
                            }
                        }
                        .frame(height: 240)
                        .accessibilityLabel("下载与上传流量趋势图")
                    }
                }

                HStack(alignment: .top, spacing: 14) {
                    GraphiteCard {
                        VStack(alignment: .leading, spacing: 14) {
                            HStack {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text("应用用量排行（估算）").font(.headline)
                                    Text(
                                        model.selectedNetworkKey == nil
                                            ? "以下排行汇总所有 Wi-Fi"
                                            : "应用用量暂不支持按 Wi-Fi 名称拆分，以下仍为全部 Wi-Fi"
                                    )
                                    .font(.caption2)
                                    .foregroundStyle(model.selectedNetworkKey == nil ? Color.secondary : Color.orange)
                                }
                                Spacer()
                                applicationSamplingBadge
                                Button("查看全部") { model.selection = .applications }
                                    .buttonStyle(.plain)
                                    .foregroundStyle(Color.usageDownload)
                            }
                            if model.applicationRows.isEmpty {
                                Text(applicationEmptyMessage)
                                    .font(.callout)
                                    .foregroundStyle(.secondary)
                            }
                            ForEach(model.applicationRows.prefix(4)) { app in
                                HStack(spacing: 10) {
                                    Image(systemName: "app.fill")
                                        .foregroundStyle(.secondary)
                                        .frame(width: 30, height: 30)
                                        .background(Color.usageCardRaised)
                                        .clipShape(RoundedRectangle(cornerRadius: 8))
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(app.name).lineLimit(1)
                                        Text(app.carrierDescription).font(.caption2).foregroundStyle(.tertiary)
                                    }
                                    Spacer()
                                    Text(app.bytes.totalDescription)
                                        .font(.callout.monospacedDigit())
                                }
                            }
                        }
                    }

                    GraphiteCard {
                        VStack(alignment: .leading, spacing: 14) {
                            Text("套餐用量").font(.headline)
                            if model.selectedNetworkKey == nil {
                                if let cost = model.estimatedCost {
                                    Text(model.estimatedCostDetail)
                                        .font(.title3.weight(.semibold))
                                    HStack {
                                        Text("当前估算")
                                        Spacer()
                                        Text(
                                            cost.currencyDescription(
                                                code: model.estimatedCostCurrencyCode ?? "CNY"
                                            )
                                        )
                                        .foregroundStyle(Color.usageCost)
                                        .fontWeight(.semibold)
                                    }
                                    Text("选择一个 Wi-Fi 可查看对应套餐额度")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                } else {
                                    Text("还没有 Wi-Fi 绑定套餐")
                                        .foregroundStyle(.secondary)
                                    Button("前往绑定") {
                                        model.selection = .wifi
                                    }
                                    .buttonStyle(.bordered)
                                }
                            } else if let plan = model.currentPlan {
                                Text(plan.name).font(.title3.weight(.semibold))
                                let included = plan.download.includedBytes
                                ProgressView(
                                    value: Double(model.currentPlanUsage.downloadedBytes),
                                    total: Double(max(included ?? model.currentPlanUsage.downloadedBytes, 1))
                                )
                                .tint(Color.usageDownload)
                                HStack {
                                    Text("已用 \(model.currentPlanUsage.downloadDescription)")
                                    Spacer()
                                    Text(included.map { "共 \($0.formattedByteCount)" } ?? "不限量")
                                }
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                Divider()
                                HStack {
                                    Text("当前估算")
                                    Spacer()
                                    Text(
                                        model.estimatedCost?.currencyDescription(
                                            code: model.estimatedCostCurrencyCode ?? plan.currencyCode
                                        ) ?? "—"
                                    )
                                        .foregroundStyle(Color.usageCost)
                                        .fontWeight(.semibold)
                                }
                            } else {
                                Text(model.selectedNetworkName)
                                    .font(.title3.weight(.semibold))
                                Text("尚未绑定套餐")
                                    .foregroundStyle(.secondary)
                                Button("前往绑定") {
                                    model.selection = .wifi
                                }
                                .buttonStyle(.bordered)
                            }
                        }
                    }
                }

                if let error = model.errorMessage {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
            .padding(24)
        }
    }

    private var applicationEmptyMessage: String {
        switch model.applicationSamplingState {
        case .stopped:
            "应用统计已暂停，可在设置中开启"
        case .starting, .running:
            "正在统计，等待应用产生 Wi-Fi 流量"
        case .failed:
            "应用用量读取失败，正在自动重试；Wi-Fi 总量不受影响"
        }
    }

    @ViewBuilder
    private var applicationSamplingBadge: some View {
        switch model.applicationSamplingState {
        case .stopped:
            Label("已暂停", systemImage: "pause.circle.fill")
                .foregroundStyle(Color.secondary)
        case .failed:
            Label("自动重试", systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(Color.orange)
        case .starting where model.applicationSamplingMode == .precise:
            Label("启动高精度", systemImage: "bolt.fill")
                .foregroundStyle(Color.orange)
        case .running where model.applicationSamplingMode == .precise:
            Label("高精度 5 分钟", systemImage: "bolt.fill")
                .foregroundStyle(Color.orange)
        case .starting:
            Label("正在启动", systemImage: "clock.arrow.circlepath")
                .foregroundStyle(Color.usageDownload)
        case .running:
            Label("低耗能", systemImage: "waveform.path.ecg")
                .foregroundStyle(Color.usageDownload)
        }
    }
}
