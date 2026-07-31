import SwiftUI

struct WiFiNetworksView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                PageHeader(title: "Wi-Fi", subtitle: "查看每个 Wi-Fi 的下载、上传和累计用量")
                UsageFilterBar()
                wifiNameAccessBanner

                if model.networkOptions.isEmpty {
                    EmptyStateCard(
                        symbol: "wifi.slash",
                        title: "没有 Wi-Fi 数据",
                        message: "连接 Wi-Fi 后，用量会陆续显示在这里。"
                    )
                } else {
                    LazyVGrid(
                        columns: [GridItem(.adaptive(minimum: 320), spacing: 14)],
                        spacing: 14
                    ) {
                        ForEach(model.networkOptions) { network in
                            networkCard(network)
                        }
                    }
                }
            }
            .padding(24)
        }
    }

    private func networkCard(_ network: WiFiUsageRow) -> some View {
        GraphiteCard {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 10) {
                    Button {
                        model.selectedNetworkKey = network.key
                    } label: {
                        HStack(spacing: 9) {
                            Image(systemName: "wifi")
                                .foregroundStyle(Color.usageDownload)
                            Text(network.name)
                                .font(.headline)
                                .lineLimit(1)
                            if network.isCurrent {
                                Text("当前连接")
                                    .font(.caption2.weight(.semibold))
                                    .padding(.horizontal, 7)
                                    .padding(.vertical, 3)
                                    .background(Color.usageDownload.opacity(0.14))
                                    .foregroundStyle(Color.usageDownload)
                                    .clipShape(Capsule())
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)

                    Spacer(minLength: 8)

                    if network.isIdentified {
                        planMenu(for: network)
                    } else if network.isCurrent {
                        Button("识别名称") {
                            openWiFiNameAccess()
                        }
                        .buttonStyle(.bordered)
                    }

                    if model.selectedNetworkKey == network.key {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(Color.usageDownload)
                            .accessibilityLabel("当前正在查看")
                    }
                }

                planStatus(for: network)

                HStack {
                    Label(network.bytes.downloadDescription, systemImage: "arrow.down")
                        .foregroundStyle(Color.usageDownload)
                    Spacer()
                    Label(network.bytes.uploadDescription, systemImage: "arrow.up")
                        .foregroundStyle(Color.usageUpload)
                }
                .font(.callout.monospacedDigit())

                Divider()

                HStack {
                    Text("累计 \(network.bytes.totalDescription)")
                    Spacer()
                    Text(network.lastSeen, style: .relative)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var wifiNameAccessBanner: some View {
        switch model.wifiNameAccessState {
        case .authorized:
            EmptyView()
        case .notDetermined:
            accessBanner(
                symbol: "wifi.exclamationmark",
                message: "允许识别 Wi-Fi 名称后，才能分别绑定套餐。"
            ) {
                model.requestSSIDAccess()
            }
        case .locationServicesDisabled:
            accessBanner(
                symbol: "location.slash.fill",
                message: "定位服务已关闭，Wi-Fi 总用量仍会继续记录。"
            ) {
                model.openWiFiNameSettings()
            }
        case .restricted, .denied:
            accessBanner(
                symbol: "wifi.exclamationmark",
                message: "Wi-Fi 名称访问未开启，总用量仍会继续记录。"
            ) {
                model.openWiFiNameSettings()
            }
        }
    }

    private func accessBanner(
        symbol: String,
        message: String,
        action: @escaping () -> Void
    ) -> some View {
        GraphiteCard {
            HStack(spacing: 12) {
                Image(systemName: symbol)
                    .foregroundStyle(Color.orange)
                Text(message)
                    .font(.callout)
                Spacer()
                Button(
                    model.wifiNameAccessState == .notDetermined
                        ? "允许识别名称"
                        : "打开系统设置",
                    action: action
                )
                .buttonStyle(.bordered)
            }
        }
    }

    private func openWiFiNameAccess() {
        if model.wifiNameAccessState == .notDetermined {
            model.requestSSIDAccess()
        } else {
            model.openWiFiNameSettings()
        }
    }

    @ViewBuilder
    private func planStatus(for network: WiFiUsageRow) -> some View {
        if let planName = network.planName {
            Label("套餐：\(planName)", systemImage: "creditcard.fill")
                .font(.caption)
                .foregroundStyle(Color.usageCost)
        } else if network.isIdentified {
            Label("尚未绑定套餐", systemImage: "creditcard")
                .font(.caption)
                .foregroundStyle(Color.orange)
        } else if network.isCurrent {
            Label("允许识别名称后可绑定套餐", systemImage: "wifi.exclamationmark")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else {
            Label("历史记录未保存 Wi-Fi 名称", systemImage: "clock.arrow.circlepath")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func planMenu(for network: WiFiUsageRow) -> some View {
        Menu {
            if model.plans.isEmpty {
                Button("添加套餐", systemImage: "plus") {
                    model.selectedNetworkKey = network.key
                    model.selection = .plans
                }
            } else {
                ForEach(model.plans) { plan in
                    Button {
                        Task {
                            _ = await model.assignPlan(plan.id, toWiFiNetwork: network.key)
                        }
                    } label: {
                        if model.planID(for: network.key) == plan.id {
                            Label(plan.name, systemImage: "checkmark")
                        } else {
                            Text(plan.name)
                        }
                    }
                }

                if model.planID(for: network.key) != nil {
                    Divider()
                    Button("解除套餐", systemImage: "xmark.circle") {
                        Task {
                            _ = await model.assignPlan(nil, toWiFiNetwork: network.key)
                        }
                    }
                }
            }
        } label: {
            Label(
                network.planName == nil ? "绑定套餐" : "更换套餐",
                systemImage: "creditcard"
            )
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }
}
