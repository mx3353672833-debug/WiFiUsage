import SwiftUI

enum UsageFilterScope {
    case physical
    case applications
}

struct PageHeader: View {
    let title: String
    let subtitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 26, weight: .bold, design: .rounded))
            Text(subtitle)
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }
}

struct UsageFilterBar: View {
    @Environment(AppModel.self) private var model
    var scope: UsageFilterScope = .physical

    var body: some View {
        @Bindable var model = model
        HStack(spacing: 12) {
            Picker("时间", selection: $model.timeFilter) {
                ForEach(UsageTimeFilter.allCases) { filter in
                    Text(filter.rawValue).tag(filter)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: 390)

            if scope == .physical {
                Picker("网络", selection: $model.selectedNetworkKey) {
                    Text("全部 Wi-Fi").tag(nil as String?)
                    ForEach(model.networkOptions) { network in
                        Text(network.name).tag(network.key as String?)
                    }
                }
                .frame(width: 170)
            }

            Spacer()

            samplingStatus
            .font(.caption)

            Button {
                Task { await model.refresh() }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            .help("刷新")
        }
    }

    @ViewBuilder
    private var samplingStatus: some View {
        switch scope {
        case .physical:
            Label(
                model.isSampling ? "Wi-Fi 正在记录" : "Wi-Fi 记录已暂停",
                systemImage: model.isSampling ? "dot.radiowaves.left.and.right" : "pause.circle"
            )
            .foregroundStyle(model.isSampling ? Color.usageDownload : Color.secondary)
        case .applications:
            switch model.applicationSamplingState {
            case .stopped:
                Label("应用统计已暂停", systemImage: "pause.circle")
                    .foregroundStyle(Color.secondary)
            case .starting where model.applicationSamplingMode == .precise:
                Label("正在启动精细统计", systemImage: "bolt.fill")
                    .foregroundStyle(Color.orange)
            case .starting:
                Label("正在启动统计", systemImage: "clock.arrow.circlepath")
                    .foregroundStyle(Color.usageDownload)
            case .running where model.applicationSamplingMode == .precise:
                Label("精细统计中", systemImage: "bolt.fill")
                    .foregroundStyle(Color.orange)
            case .running:
                Label("低耗能统计中", systemImage: "waveform.path.ecg")
                    .foregroundStyle(Color.usageDownload)
            case .failed:
                Label("统计遇到问题，自动重试中", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(Color.orange)
            }
        }
    }
}
