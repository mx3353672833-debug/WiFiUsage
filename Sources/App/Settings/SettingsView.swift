import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var isFeedbackPresented = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                PageHeader(title: "设置", subtitle: "管理流量记录、Wi-Fi 名称和自动启动")

                GraphiteCard {
                    VStack(alignment: .leading, spacing: 14) {
                        Text("流量与数据").font(.headline)
                        LabeledContent("本地数据") {
                            Label(model.repositoryReady ? "可用" : "不可用", systemImage: model.repositoryReady ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                                .foregroundStyle(model.repositoryReady ? Color.usageDownload : Color.orange)
                        }
                        LabeledContent("Wi-Fi 总用量") {
                            Label(model.isSampling ? "正在记录" : "未运行", systemImage: model.isSampling ? "checkmark.circle.fill" : "pause.circle")
                                .foregroundStyle(model.isSampling ? Color.usageDownload : Color.secondary)
                        }
                        LabeledContent("最近更新") {
                            Text(model.lastUpdated?.formatted(date: .abbreviated, time: .standard) ?? "尚无数据")
                        }
                        LabeledContent("Wi-Fi 名称") {
                            Label(wifiNameAccessText, systemImage: wifiNameAccessSymbol)
                                .foregroundStyle(wifiNameAccessColor)
                        }
                        if model.allowsLocationSSIDAccess && model.currentSSID == nil {
                            switch model.wifiNameAccessState {
                            case .notDetermined:
                                Button("允许识别 Wi-Fi 名称") {
                                    model.requestSSIDAccess()
                                }
                            case .locationServicesDisabled, .restricted, .denied:
                                Button("打开系统设置") {
                                    model.openWiFiNameSettings()
                                }
                            case .notRequired, .authorized:
                                EmptyView()
                            }
                        }
                    }
                }

                GraphiteCard {
                    VStack(alignment: .leading, spacing: 14) {
                        Text("应用用量统计").font(.headline)
                        LabeledContent("统计方式") {
                            Label("仅在本机估算", systemImage: "checkmark.shield.fill")
                                .foregroundStyle(Color.usageDownload)
                        }
                        LabeledContent("记录模式") {
                            Picker(
                                "记录模式",
                                selection: Binding(
                                    get: { model.applicationSamplingMode },
                                    set: { mode in
                                        Task { await model.setApplicationSamplingMode(mode) }
                                    }
                                )
                            ) {
                                ForEach(ApplicationSamplingMode.allCases) { mode in
                                    Text(mode.title).tag(mode)
                                }
                            }
                            .labelsHidden()
                            .frame(width: 180)
                            .disabled(
                                !model.repositoryReady
                                    || !model.isApplicationSamplingRequested
                                    || model.isChangingApplicationSamplingMode
                            )
                        }
                        LabeledContent("状态") {
                            Label(
                                applicationSamplingStatusText,
                                systemImage: samplingStatusSymbol
                            )
                            .foregroundStyle(samplingStatusColor)
                        }
                        LabeledContent("应用用量最近更新") {
                            Text(model.lastApplicationSampleAt?.formatted(date: .abbreviated, time: .standard) ?? "等待流量")
                        }
                        LabeledContent("当前时段已识别") {
                            Text("\(model.trackedApplicationCount) 个")
                        }
                        HStack {
                            if case .failed = model.applicationSamplingState {
                                Button("立即重试") {
                                    Task { await model.retryApplicationSampling() }
                                }
                                .buttonStyle(.borderedProminent)
                                .tint(Color.usageDownload)
                                Button("暂停重试") {
                                    Task { await model.stopApplicationSampling() }
                                }
                            } else if model.isApplicationSamplingRequested {
                                Button("暂停统计") {
                                    Task { await model.stopApplicationSampling() }
                                }
                            } else {
                                Button("开始统计") {
                                    Task { await model.startApplicationSampling() }
                                }
                                .buttonStyle(.borderedProminent)
                                .tint(Color.usageDownload)
                            }
                            Button("刷新数据") { Task { await model.refresh() } }
                        }
                        .disabled(
                            !model.repositoryReady
                                || model.isChangingApplicationSamplingMode
                                || model.isRetryingApplicationSampling
                        )
                        Text(model.applicationSamplingMode.detail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        if model.applicationSamplingMode == .precise {
                            if let end = model.preciseSamplingEndsAt {
                                LabeledContent("自动恢复低耗能") {
                                    Text(end.formatted(date: .omitted, time: .shortened))
                                        .monospacedDigit()
                                }
                            }
                            Label(
                                "高精度模式会明显增加处理器占用和耗电，仅建议临时使用，最多运行 5 分钟。",
                                systemImage: "bolt.trianglebadge.exclamationmark"
                            )
                            .font(.caption)
                            .foregroundStyle(.orange)
                            if model.isApplicationSamplingRequested {
                                Button("立即结束高精度") {
                                    Task { await model.setApplicationSamplingMode(.balanced) }
                                }
                                .disabled(model.isChangingApplicationSamplingMode)
                            }
                        }
                        Text("无需额外安装或付费，数据只在这台 Mac 上处理。应用用量仅在流量账本运行时估算；VPN、代理和很快结束的连接可能无法完整识别。总用量和总费用以 Wi-Fi 页面为准。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        if model.applicationSamplingError != nil {
                            Label("应用用量读取遇到问题，正在自动重试。", systemImage: "exclamationmark.triangle")
                                .font(.caption)
                                .foregroundStyle(.orange)
                        }
                    }
                }

                GraphiteCard {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("启动与显示").font(.headline)
                        Toggle(
                            "登录时启动",
                            isOn: Binding(
                                get: { model.launchAtLoginEnabled },
                                set: { enabled in Task { await model.setLaunchAtLogin(enabled) } }
                            )
                        )
                        .disabled(model.isChangingLaunchAtLogin)
                        LabeledContent("状态") {
                            Text(
                                model.launchAtLoginState == .notFound
                                    ? "请先移到“应用程序”文件夹"
                                    : model.launchAtLoginStatusText
                            )
                        }
                        if model.launchAtLoginState == .requiresApproval {
                            Button("打开登录项设置") { model.openLoginItemsSettings() }
                        } else if model.launchAtLoginState == .notFound {
                            HStack {
                                Button("在 Finder 中显示 WiFiUsage") { model.revealCurrentApplication() }
                                Button("打开“应用程序”") { model.openApplicationsFolder() }
                                Button("登录项设置") { model.openLoginItemsSettings() }
                            }
                        }
                        Text("建议开启“登录时启动”，可减少应用未运行期间的统计缺口。界面固定使用深色石墨主题。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                DiagnosticFeedbackCard(isFeedbackPresented: $isFeedbackPresented)

                if let error = model.errorMessage {
                    HStack {
                        Label(error, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                            .font(.caption)
                        Spacer()
                        Button("反馈这个问题") { isFeedbackPresented = true }
                            .font(.caption)
                    }
                }
            }
            .padding(24)
        }
        .background(Color.usageBackground)
        .task { model.refreshLaunchAtLogin() }
        .sheet(isPresented: $isFeedbackPresented) {
            FeedbackSheet()
                .environment(model)
                .preferredColorScheme(.dark)
        }
    }

    private var samplingStatusSymbol: String {
        switch model.applicationSamplingState {
        case .stopped: "pause.circle"
        case .starting: "clock.arrow.circlepath"
        case .running:
            model.applicationSamplingMode == .precise ? "bolt.fill" : "waveform.path.ecg"
        case .failed: "exclamationmark.triangle.fill"
        }
    }

    private var wifiNameAccessText: String {
        if let ssid = model.currentSSID {
            return "已识别 · \(ssid)"
        }
        if !model.allowsLocationSSIDAccess || model.wifiNameAccessState == .notRequired {
            return model.currentWiFiNetwork == nil
                ? "连接 Wi-Fi 后自动识别"
                : "正在自动识别 Wi-Fi 名称"
        }
        switch model.wifiNameAccessState {
        case .locationServicesDisabled: return "定位服务已关闭"
        case .notDetermined: return "尚未允许"
        case .restricted: return "当前设置不允许"
        case .denied: return "未允许"
        case .authorized: return "正在自动识别"
        case .notRequired: return "自动识别，无需定位权限"
        }
    }

    private var wifiNameAccessSymbol: String {
        if model.currentSSID != nil {
            return "checkmark.circle.fill"
        }
        if !model.allowsLocationSSIDAccess || model.wifiNameAccessState == .notRequired {
            return model.currentWiFiNetwork == nil ? "wifi.slash" : "clock.arrow.circlepath"
        }
        return "exclamationmark.triangle.fill"
    }

    private var wifiNameAccessColor: Color {
        if model.currentSSID != nil {
            return .usageDownload
        }
        if !model.allowsLocationSSIDAccess || model.wifiNameAccessState == .notRequired {
            return .secondary
        }
        return .orange
    }

    private var applicationSamplingStatusText: String {
        switch model.applicationSamplingState {
        case .stopped: "已暂停"
        case .starting:
            model.applicationSamplingMode == .precise ? "正在启动精细统计" : "正在启动"
        case .running:
            model.applicationSamplingMode == .precise ? "精细统计中" : "正在统计"
        case .failed: "读取失败，正在自动重试"
        }
    }

    private var samplingStatusColor: Color {
        switch model.applicationSamplingState {
        case .stopped: .secondary
        case .starting, .running:
            model.applicationSamplingMode == .precise ? .orange : .usageDownload
        case .failed: .orange
        }
    }
}
