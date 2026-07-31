import SwiftUI
import UsageCore

struct PlansView: View {
    @Environment(AppModel.self) private var model
    @State private var showingForm = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack {
                    PageHeader(title: "套餐", subtitle: "为每个 Wi-Fi 绑定套餐，按额度估算费用")
                    Spacer()
                    Button("添加套餐", systemImage: "plus") { showingForm = true }
                        .buttonStyle(.borderedProminent)
                        .tint(Color.usageDownload)
                }

                if model.plans.isEmpty {
                    EmptyStateCard(
                        symbol: "creditcard",
                        title: "还没有套餐",
                        message: "添加套餐并绑定到 Wi-Fi 后，即可估算费用。"
                    )
                } else {
                    ForEach(model.plans) { plan in
                        planCard(plan)
                    }
                }
            }
            .padding(24)
        }
        .sheet(isPresented: $showingForm) {
            PlanFormView(isPresented: $showingForm)
                .environment(model)
        }
    }

    private func planCard(_ plan: UsagePlan) -> some View {
        let assignedNetworks = model.networkOptions.filter {
            model.planID(for: $0.key) == plan.id
        }

        return GraphiteCard {
            HStack(alignment: .top, spacing: 18) {
                Image(systemName: "creditcard.fill")
                    .font(.title2)
                    .foregroundStyle(Color.usageCost)
                    .frame(width: 50, height: 50)
                    .background(Color.usageCost.opacity(0.14))
                    .clipShape(RoundedRectangle(cornerRadius: 12))

                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        Text(plan.name)
                            .font(.title3.weight(.semibold))
                        if !assignedNetworks.isEmpty {
                            Text("已绑定 \(assignedNetworks.count) 个 Wi-Fi")
                                .font(.caption2.weight(.semibold))
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(Color.usageDownload.opacity(0.15))
                                .foregroundStyle(Color.usageDownload)
                                .clipShape(Capsule())
                        }
                    }

                    Text("基础费用 \(plan.basePrice.currencyDescription(code: plan.currencyCode))")
                        .foregroundStyle(.secondary)

                    HStack(spacing: 24) {
                        planDirection("下载", plan: plan.download, color: .usageDownload)
                        planDirection("上传", plan: plan.upload, color: .usageUpload)
                    }

                    if assignedNetworks.isEmpty {
                        Label("尚未绑定 Wi-Fi", systemImage: "wifi.exclamationmark")
                            .font(.caption)
                            .foregroundStyle(Color.orange)
                    } else {
                        Label(
                            "用于：\(assignedNetworks.map(\.name).joined(separator: "、"))",
                            systemImage: "wifi"
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                    }
                }

                Spacer(minLength: 12)
                networkAssignmentControl(for: plan)
            }
        }
    }

    @ViewBuilder
    private func networkAssignmentControl(for plan: UsagePlan) -> some View {
        let networks = model.networkOptions.filter(\.isIdentified)

        if networks.isEmpty {
            switch model.wifiNameAccessState {
            case .notDetermined:
                Button("识别 Wi-Fi 名称") {
                    model.requestSSIDAccess()
                }
                .buttonStyle(.bordered)
            case .authorized:
                Label("连接 Wi-Fi 后可绑定", systemImage: "wifi.slash")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            case .locationServicesDisabled, .restricted, .denied:
                Button("打开系统设置") {
                    model.openWiFiNameSettings()
                }
                .buttonStyle(.bordered)
            }
        } else {
            Menu {
                ForEach(networks) { network in
                    let isAssigned = model.planID(for: network.key) == plan.id
                    Button {
                        Task { @MainActor in
                            _ = await model.assignPlan(
                                isAssigned ? nil : plan.id,
                                toWiFiNetwork: network.key
                            )
                        }
                    } label: {
                        Label(
                            network.name,
                            systemImage: isAssigned ? "checkmark.circle.fill" : "circle"
                        )
                    }
                }
            } label: {
                Label("管理 Wi-Fi", systemImage: "wifi")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
    }

    private func planDirection(_ title: String, plan: DirectionalDataPlan, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.caption)
                .foregroundStyle(color)
            Text(plan.includedBytes.map { $0.formattedByteCount } ?? "不限量")
            Text("超额 \(NSDecimalNumber(decimal: plan.overagePricePerGigabyte).stringValue)/GB")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }
}

private struct PlanFormView: View {
    @Environment(AppModel.self) private var model
    @Binding var isPresented: Bool
    @State private var name = ""
    @State private var currencyCode = "CNY"
    @State private var basePrice = 0.0
    @State private var unlimitedDownload = false
    @State private var unlimitedUpload = false
    @State private var downloadGB = 200.0
    @State private var uploadGB = 50.0
    @State private var downloadOverage = 0.5
    @State private var uploadOverage = 0.8
    @State private var selectedNetworkIDs: Set<String> = []
    @State private var didPrepareNetworkSelection = false
    @State private var validationMessage: String?
    @State private var isSaving = false
    @State private var savedPlanID: UUID?

    private static let currencyOptions = [
        CurrencyOption(code: "CNY", title: "人民币（CNY）"),
        CurrencyOption(code: "USD", title: "美元（USD）"),
        CurrencyOption(code: "EUR", title: "欧元（EUR）"),
        CurrencyOption(code: "JPY", title: "日元（JPY）"),
        CurrencyOption(code: "HKD", title: "港币（HKD）")
    ]

    private var identifiedNetworks: [WiFiUsageRow] {
        model.networkOptions.filter(\.isIdentified)
    }

    private var validationError: String? {
        if name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "请输入套餐名称"
        }
        if !basePrice.isFinite || basePrice < 0 {
            return "基础费用不能为负数"
        }
        if !downloadOverage.isFinite || downloadOverage < 0
            || !uploadOverage.isFinite || uploadOverage < 0 {
            return "超额单价不能为负数"
        }
        if !unlimitedDownload && (!downloadGB.isFinite || downloadGB < 0) {
            return "下载额度不能为负数"
        }
        if !unlimitedUpload && (!uploadGB.isFinite || uploadGB < 0) {
            return "上传额度不能为负数"
        }
        return nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(savedPlanID == nil ? "添加套餐" : "完成 Wi-Fi 绑定")
                .font(.title2.bold())

            Form {
                Section("套餐信息") {
                    TextField("名称", text: $name)
                    Picker("币种", selection: $currencyCode) {
                        ForEach(Self.currencyOptions) { option in
                            Text(option.title).tag(option.code)
                        }
                    }
                    TextField("基础费用", value: $basePrice, format: .number)
                }

                Section("用于哪些 Wi-Fi") {
                    if identifiedNetworks.isEmpty {
                        Text("允许识别 Wi-Fi 名称后，可以在这里选择。")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(identifiedNetworks) { network in
                            Toggle(
                                network.name,
                                isOn: Binding(
                                    get: { selectedNetworkIDs.contains(network.key) },
                                    set: { isSelected in
                                        if isSelected {
                                            selectedNetworkIDs.insert(network.key)
                                        } else {
                                            selectedNetworkIDs.remove(network.key)
                                        }
                                    }
                                )
                            )
                        }
                    }
                }

                Section("下载") {
                    Toggle("不限量", isOn: $unlimitedDownload)
                    TextField("包含 GB", value: $downloadGB, format: .number)
                        .disabled(unlimitedDownload)
                    TextField("超额单价 / GB", value: $downloadOverage, format: .number)
                }

                Section("上传") {
                    Toggle("不限量", isOn: $unlimitedUpload)
                    TextField("包含 GB", value: $uploadGB, format: .number)
                        .disabled(unlimitedUpload)
                    TextField("超额单价 / GB", value: $uploadOverage, format: .number)
                }
            }
            .disabled(savedPlanID != nil)

            if let message = validationMessage ?? validationError {
                Label(message, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            HStack {
                Spacer()
                Button("取消") { isPresented = false }
                    .disabled(isSaving)
                Button(savedPlanID == nil ? "保存" : "重试绑定") {
                    save()
                }
                .disabled(isSaving || validationError != nil)
                .buttonStyle(.borderedProminent)
                .tint(Color.usageDownload)
            }
        }
        .padding(24)
        .frame(width: 560, height: 680)
        .background(Color.usageBackground)
        .onAppear {
            prepareNetworkSelection()
        }
    }

    private func prepareNetworkSelection() {
        guard !didPrepareNetworkSelection else { return }
        didPrepareNetworkSelection = true

        if let selectedNetworkKey = model.selectedNetworkKey,
           identifiedNetworks.contains(where: { $0.key == selectedNetworkKey }) {
            selectedNetworkIDs.insert(selectedNetworkKey)
        }
    }

    private func save() {
        guard validationError == nil else {
            validationMessage = validationError
            return
        }

        isSaving = true
        validationMessage = nil

        Task { @MainActor in
            let planID: UUID
            if let savedPlanID {
                planID = savedPlanID
            } else {
                let existingPlanIDs = Set(model.plans.map(\.id))
                let saved = await model.savePlan(
                    name: name,
                    currencyCode: currencyCode,
                    basePrice: Decimal(basePrice),
                    downloadGB: unlimitedDownload ? nil : downloadGB,
                    uploadGB: unlimitedUpload ? nil : uploadGB,
                    downloadOverage: Decimal(downloadOverage),
                    uploadOverage: Decimal(uploadOverage)
                )

                guard saved,
                      let newPlan = model.plans.first(where: { !existingPlanIDs.contains($0.id) }) else {
                    isSaving = false
                    validationMessage = model.errorMessage ?? "套餐保存失败，请稍后重试。"
                    return
                }
                savedPlanID = newPlan.id
                planID = newPlan.id
            }

            var didAssignEveryNetwork = true
            for network in model.networkOptions
                where network.isIdentified && selectedNetworkIDs.contains(network.key) {
                let assigned = await model.assignPlan(
                    planID,
                    toWiFiNetwork: network.key
                )
                didAssignEveryNetwork = didAssignEveryNetwork && assigned
            }

            isSaving = false
            if didAssignEveryNetwork {
                isPresented = false
            } else {
                validationMessage = model.errorMessage
                    ?? "套餐已保存，但部分 Wi-Fi 暂时无法绑定，请稍后重试。"
            }
        }
    }
}

private struct CurrencyOption: Identifiable {
    let code: String
    let title: String
    var id: String { code }
}
