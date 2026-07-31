import SwiftUI

struct MenuBarUsageView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(model.selectedNetworkName)
                        .font(.headline)
                        .foregroundStyle(Color.white)
                    Text(model.timeFilter.rawValue)
                        .font(.caption)
                        .foregroundStyle(Color.white.opacity(0.68))
                }
                Spacer()
                Image(systemName: "chart.bar.fill")
                    .foregroundStyle(model.isSampling ? Color.usageDownload : Color.white.opacity(0.72))
            }

            HStack(spacing: 10) {
                menuMetric("下载", model.totalUsage.downloadDescription, .usageDownload, "arrow.down")
                menuMetric("上传", model.totalUsage.uploadDescription, .usageUpload, "arrow.up")
            }

            HStack {
                Text("累计")
                    .foregroundStyle(Color.white)
                Spacer()
                Text(model.totalUsage.totalDescription)
                    .foregroundStyle(Color.white)
                    .monospacedDigit()
            }
            HStack {
                Text("估算费用")
                    .foregroundStyle(Color.white)
                Spacer()
                Text(
                    model.estimatedCost?.currencyDescription(
                        code: model.estimatedCostCurrencyCode ?? "CNY"
                    ) ?? "—"
                )
                    .foregroundStyle(model.estimatedCost == nil ? Color.white.opacity(0.46) : Color.usageCost)
            }
            .font(.callout)

            Text(model.estimatedCostDetail)
                .font(.caption2)
                .foregroundStyle(Color.white.opacity(0.58))

            Divider()
                .overlay(Color.white.opacity(0.22))
            HStack {
                Button("打开主窗口") {
                    openWindow(id: "main")
                    NSApp.activate(ignoringOtherApps: true)
                }
                .foregroundStyle(Color.white)
                Spacer()
                Button("退出") { NSApp.terminate(nil) }
                    .foregroundStyle(Color.white)
            }
        }
        .padding(16)
        .frame(width: 310)
        .background(Color.usageBackground)
    }

    private func menuMetric(_ title: String, _ value: String, _ color: Color, _ symbol: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Label(title, systemImage: symbol).font(.caption).foregroundStyle(color)
            Text(value)
                .font(.title3.weight(.semibold))
                .foregroundStyle(Color.white)
                .monospacedDigit()
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.usageCard)
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }
}
