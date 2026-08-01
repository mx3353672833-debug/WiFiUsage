import AppKit
import Foundation
import Observation
import SystemBridge
import UsageCore

public enum UsageTimeFilter: String, CaseIterable, Identifiable, Sendable {
    case today = "今日"
    case last24Hours = "24H"
    case last7Days = "7天"
    case thisMonth = "本月"
    case thisYear = "今年"

    public var id: String { rawValue }

    func interval(now: Date = Date(), calendar: Calendar = .current) -> DateInterval {
        let start: Date
        switch self {
        case .today:
            start = calendar.startOfDay(for: now)
        case .last24Hours:
            start = calendar.date(byAdding: .hour, value: -24, to: now) ?? now
        case .last7Days:
            start = calendar.date(byAdding: .day, value: -7, to: now) ?? now
        case .thisMonth:
            start = calendar.dateInterval(of: .month, for: now)?.start ?? now
        case .thisYear:
            start = calendar.dateInterval(of: .year, for: now)?.start ?? now
        }
        return DateInterval(start: start, end: now.addingTimeInterval(1))
    }
}

public enum AppSection: String, CaseIterable, Identifiable {
    case overview = "概览"
    case wifi = "Wi-Fi"
    case applications = "应用"
    case plans = "套餐"
    case settings = "设置"

    public var id: String { rawValue }

    var symbol: String {
        switch self {
        case .overview: "square.grid.2x2"
        case .wifi: "wifi"
        case .applications: "app.badge"
        case .plans: "creditcard"
        case .settings: "gearshape"
        }
    }
}

public struct UsageChartPoint: Identifiable, Sendable {
    public let id: Date
    public let date: Date
    public let downloaded: Double
    public let uploaded: Double
}

public struct ApplicationUsageRow: Identifiable, Sendable {
    public var id: String { identifier }
    public let identifier: String
    public let name: String
    public let iconPath: String?
    public let carrier: CarrierKind
    public let bytes: UsageBytes
    public let estimatedCost: Decimal?

    public var carrierDescription: String {
        carrier == .wifi ? "Wi-Fi 估算" : "历史数据"
    }

    public var carrierSymbol: String {
        carrier == .wifi ? "wifi" : "waveform.path.ecg"
    }
}

public struct WiFiUsageRow: Identifiable, Sendable {
    public var id: String { key }
    public let key: String
    public let name: String
    public let isIdentified: Bool
    public let isCurrent: Bool
    public let bytes: UsageBytes
    public let lastSeen: Date
    public let planName: String?
}

@MainActor
@Observable
public final class AppModel {
    private static let databaseFileName = "usage.sqlite"
    private static let legacyAppGroupIdentifier = "group.one.xjp.WiFiUsage"

    public var selection: AppSection? = .overview
    public var timeFilter: UsageTimeFilter = .today {
        didSet { scheduleRefresh() }
    }
    public var selectedNetworkKey: String? {
        didSet { scheduleRefresh() }
    }
    public private(set) var physicalSamples: [PhysicalUsageSample] = []
    public private(set) var applicationTotals: [ApplicationUsageTotal] = []
    public private(set) var knownWiFiNetworks: [KnownWiFiNetwork] = []
    public private(set) var wifiPlanAssignments: [String: UUID] = [:]
    public private(set) var plans: [UsagePlan] = []
    public private(set) var isSampling = false
    public private(set) var currentWiFiNetwork: WiFiNetworkIdentity?
    public private(set) var wifiNameAccessState: WiFiNameAccessState = .notDetermined
    public private(set) var lastUpdated: Date?
    public private(set) var errorMessage: String?
    public private(set) var repositoryReady = false
    public private(set) var applicationSamplingState: ApplicationSamplingState = .stopped
    public private(set) var applicationSamplingMode: ApplicationSamplingMode = .balanced
    public private(set) var preciseSamplingEndsAt: Date?
    public private(set) var isChangingApplicationSamplingMode = false
    public private(set) var isRetryingApplicationSampling = false
    public private(set) var lastApplicationSampleAt: Date?
    public private(set) var applicationSamplingError: String?
    public private(set) var launchAtLoginState: LaunchAtLoginState = .notRegistered
    public private(set) var isChangingLaunchAtLogin = false

    @ObservationIgnored private var repository: (any UsageRepository)?
    @ObservationIgnored private var sampler: PhysicalWiFiSampler?
    @ObservationIgnored private var applicationSampler: ProcessNetworkSampler?
    @ObservationIgnored private var applicationFlushTask: Task<Void, Never>?
    @ObservationIgnored private var preciseModeTask: Task<Void, Never>?
    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    @ObservationIgnored private var networkMonitorTask: Task<Void, Never>?
    @ObservationIgnored private var refreshGeneration: UInt64 = 0
    @ObservationIgnored private var wifiStatusGeneration: UInt64 = 0
    @ObservationIgnored private var applicationDataRevision: UInt64 = 0
    @ObservationIgnored private var pendingApplicationUsage: [String: PendingApplicationUsage] = [:]
    @ObservationIgnored private var applicationMetadata: [String: ApplicationMetadata] = [:]
    @ObservationIgnored private let runtimeConfiguration: AppRuntimeConfiguration
    @ObservationIgnored private let networkResolver: any WiFiNetworkResolving
    @ObservationIgnored private let launchAtLoginManager: any LaunchAtLoginManaging
    @ObservationIgnored private let preferences: UserDefaults
    @ObservationIgnored private var registeredCurrentNetworkID: String?
    @ObservationIgnored private var didInitializeNetworkSelection = false
    @ObservationIgnored private var lastIdentifiedCurrentNetworkID: String?

    private static let applicationSamplingEnabledKey = "applicationSamplingEnabled"
    private static let applicationBucketDuration: TimeInterval = 5 * 60
    private static let preciseSamplingDuration: TimeInterval = 5 * 60

    private struct PendingApplicationUsage {
        var startedAt: Date
        var endedAt: Date
        var bytes: UsageBytes
    }

    private struct ApplicationMetadata {
        let name: String
        let iconPath: String?
    }

    private struct ResolvedApplication {
        let identifier: String
        let metadata: ApplicationMetadata
    }

    private struct PlanCostContext {
        let plan: UsagePlan
        let usage: UsageBytes
        let cost: UsageCostBreakdown
    }

    public init(
        runtimeConfiguration: AppRuntimeConfiguration = .current,
        networkResolver: (any WiFiNetworkResolving)? = nil,
        launchAtLoginManager: any LaunchAtLoginManaging = LaunchAtLoginManager(),
        preferences: UserDefaults = .standard,
        automaticallyBootstraps: Bool = true
    ) {
        self.runtimeConfiguration = runtimeConfiguration
        self.networkResolver = networkResolver
            ?? WiFiNetworkResolver(runtimeConfiguration: runtimeConfiguration)
        self.launchAtLoginManager = launchAtLoginManager
        self.preferences = preferences
        wifiNameAccessState = runtimeConfiguration.allowsLocationSSIDAccess
            ? self.networkResolver.wifiNameAccessState
            : .notRequired
        self.networkResolver.onWiFiNameAccessStateChange = { [weak self] state in
            guard let self else { return }
            self.wifiNameAccessState = self.runtimeConfiguration.allowsLocationSSIDAccess
                ? state
                : .notRequired
            Task { [weak self] in
                await self?.refreshWiFiStatus()
            }
        }
        if automaticallyBootstraps {
            Task { [weak self] in
                await self?.bootstrap()
            }
        }
    }

    deinit {
        applicationFlushTask?.cancel()
        preciseModeTask?.cancel()
        refreshTask?.cancel()
        networkMonitorTask?.cancel()
    }

    public var interval: DateInterval { timeFilter.interval() }

    public var currentSSID: String? {
        guard let ssid = currentWiFiNetwork?.ssid, !ssid.isEmpty else { return nil }
        return ssid
    }

    public var currentNetworkKey: String? {
        guard currentSSID != nil else { return nil }
        return currentWiFiNetwork?.networkID
    }

    public var allowsLocationSSIDAccess: Bool {
        runtimeConfiguration.allowsLocationSSIDAccess
    }

    public var isPublicDistribution: Bool {
        runtimeConfiguration.isPublicDistribution
    }

    public var visiblePhysicalSamples: [PhysicalUsageSample] {
        let currentInterval = interval
        return physicalSamples.filter { sample in
            sample.endedAt > currentInterval.start
                && sample.endedAt <= currentInterval.end
                && (selectedNetworkKey == nil || sample.network.networkID == selectedNetworkKey)
        }
    }

    public var totalUsage: UsageBytes {
        visiblePhysicalSamples.reduce(.zero) { $0 + $1.bytes }
    }

    public var allWiFiUsage: UsageBytes {
        let currentInterval = interval
        return physicalSamples.reduce(.zero) { result, sample in
            guard sample.endedAt > currentInterval.start, sample.endedAt <= currentInterval.end else {
                return result
            }
            return result + sample.bytes
        }
    }

    public var currentPlan: UsagePlan? {
        selectedPlanContext?.plan
    }

    public var costBreakdown: UsageCostBreakdown? {
        selectedNetworkKey == nil ? aggregateCostBreakdown : selectedPlanContext?.cost
    }

    public var estimatedCost: Decimal? { costBreakdown?.total }

    public var estimatedCostCurrencyCode: String? {
        costBreakdown?.currencyCode
    }

    public var estimatedCostDetail: String {
        if selectedNetworkKey != nil {
            return currentPlan?.name ?? "未设置套餐"
        }
        let contexts = planCostContexts
        guard !contexts.isEmpty else { return "尚未绑定套餐" }
        guard aggregateCostBreakdown != nil else { return "包含多种货币" }
        return "\(contexts.count) 个套餐合计"
    }

    public var currentPlanUsage: UsageBytes {
        selectedPlanContext?.usage ?? .zero
    }

    public var selectedNetworkName: String {
        guard let selectedNetworkKey else { return "全部 Wi-Fi" }
        return networkOptions.first(where: { $0.key == selectedNetworkKey })?.name
            ?? "已选 Wi-Fi"
    }

    public func planID(for networkID: String) -> UUID? {
        wifiPlanAssignments[networkID]
    }

    public func plan(for networkID: String) -> UsagePlan? {
        guard let planID = planID(for: networkID) else { return nil }
        return plans.first { $0.id == planID }
    }

    public var networkOptions: [WiFiUsageRow] {
        let groups = Dictionary(grouping: physicalSamples) { $0.network.networkID }
        var networksByID = Dictionary(
            uniqueKeysWithValues: knownWiFiNetworks.map { ($0.id, $0) }
        )
        if let currentWiFiNetwork {
            let now = Date()
            let live = KnownWiFiNetwork(identity: currentWiFiNetwork, observedAt: now)
            if let existing = networksByID[live.id] {
                networksByID[live.id] = KnownWiFiNetwork(
                    id: live.id,
                    ssid: live.ssid ?? existing.ssid,
                    interfaceName: live.interfaceName,
                    firstSeenAt: min(existing.firstSeenAt, live.firstSeenAt),
                    lastSeenAt: max(existing.lastSeenAt, live.lastSeenAt)
                )
            } else {
                networksByID[live.id] = live
            }
        }
        for (networkID, samples) in groups where networksByID[networkID] == nil {
            guard let identity = samples.last?.network else { continue }
            networksByID[networkID] = KnownWiFiNetwork(
                id: networkID,
                ssid: identity.ssid,
                interfaceName: identity.interfaceName,
                firstSeenAt: samples.map(\.startedAt).min() ?? .distantPast,
                lastSeenAt: samples.map(\.endedAt).max() ?? .distantPast
            )
        }

        return networksByID.values.map { network in
            let samples = groups[network.id] ?? []
            let identified = network.isIdentified
            return WiFiUsageRow(
                key: network.id,
                name: identified
                    ? (network.ssid ?? "Wi-Fi")
                    : (currentWiFiNetwork?.networkID == network.id
                        ? "当前 Wi-Fi（名称未识别）"
                        : "未识别的历史用量"),
                isIdentified: identified,
                isCurrent: currentWiFiNetwork?.networkID == network.id,
                bytes: samples.reduce(.zero) { $0 + $1.bytes },
                lastSeen: max(
                    network.lastSeenAt,
                    samples.map(\.endedAt).max() ?? .distantPast
                ),
                planName: plan(for: network.id)?.name
            )
        }
        .sorted {
            if $0.isCurrent != $1.isCurrent { return $0.isCurrent }
            if $0.isIdentified != $1.isIdentified { return $0.isIdentified }
            return $0.lastSeen > $1.lastSeen
        }
    }

    public var applicationRows: [ApplicationUsageRow] {
        let combined = Dictionary(grouping: applicationTotals, by: \.applicationIdentifier)
            .map { identifier, totals in
                let wifiTotals = totals.filter { $0.carrier == .wifi }
                let visibleTotals = wifiTotals.isEmpty ? totals : wifiTotals
                return ApplicationUsageTotal(
                    applicationIdentifier: identifier,
                    carrier: wifiTotals.isEmpty ? .unknown : .wifi,
                    bytes: visibleTotals.reduce(.zero) { $0 + $1.bytes }
                )
            }
        let allocation = applicationCostAllocation.map {
            Dictionary(uniqueKeysWithValues: $0.applications.map {
                ($0.applicationIdentifier, $0.estimatedCost)
            })
        } ?? [:]

        return combined.map { total in
            let metadata = metadata(for: total.applicationIdentifier)
            return ApplicationUsageRow(
                identifier: total.applicationIdentifier,
                name: metadata.name,
                iconPath: metadata.iconPath,
                carrier: total.carrier,
                bytes: total.bytes,
                estimatedCost: allocation[total.applicationIdentifier]
            )
        }
        .sorted { $0.bytes.totalBytes > $1.bytes.totalBytes }
    }

    public var unallocatedApplicationCost: Decimal? {
        applicationCostAllocation?.unallocatedCost
    }

    public var applicationCostCurrencyCode: String? {
        aggregateCostBreakdown?.currencyCode
    }

    private var applicationCostAllocation: ApplicationCostAllocation? {
        guard let cost = aggregateCostBreakdown else { return nil }
        return ApplicationCostAllocator.allocate(
            applications: applicationTotals.filter { $0.carrier == .wifi },
            physicalUsage: allWiFiUsage,
            cost: cost
        )
    }

    private var selectedPlanContext: PlanCostContext? {
        guard let selectedNetworkKey,
              let planID = wifiPlanAssignments[selectedNetworkKey] else {
            return nil
        }
        return planCostContexts.first { $0.plan.id == planID }
    }

    private var planCostContexts: [PlanCostContext] {
        let assignmentsByPlan = Dictionary(
            grouping: wifiPlanAssignments,
            by: { $0.value }
        )
        return assignmentsByPlan.compactMap { planID, assignments in
            guard let plan = plans.first(where: { $0.id == planID }) else { return nil }
            let networkIDs = Set(assignments.map { $0.key })
            let usage = usage(for: networkIDs)
            return PlanCostContext(
                plan: plan,
                usage: usage,
                cost: UsageBilling.cost(for: usage, plan: plan)
            )
        }
    }

    private var aggregateCostBreakdown: UsageCostBreakdown? {
        let contexts = planCostContexts
        guard !contexts.isEmpty else { return nil }
        let currencyCodes = Set(contexts.map(\.cost.currencyCode))
        guard currencyCodes.count == 1, let currencyCode = currencyCodes.first else {
            return nil
        }
        return UsageCostBreakdown(
            currencyCode: currencyCode,
            basePrice: contexts.reduce(0) { $0 + $1.cost.basePrice },
            downloadOverage: contexts.reduce(0) { $0 + $1.cost.downloadOverage },
            uploadOverage: contexts.reduce(0) { $0 + $1.cost.uploadOverage }
        )
    }

    private func usage(for networkIDs: Set<String>) -> UsageBytes {
        let currentInterval = interval
        return physicalSamples.reduce(.zero) { result, sample in
            guard networkIDs.contains(sample.network.networkID),
                  sample.endedAt > currentInterval.start,
                  sample.endedAt <= currentInterval.end else {
                return result
            }
            return result + sample.bytes
        }
    }

    public var chartPoints: [UsageChartPoint] {
        let samples = visiblePhysicalSamples.sorted { $0.endedAt < $1.endedAt }
        guard !samples.isEmpty else { return [] }
        let bucketCount = timeFilter == .today || timeFilter == .last24Hours ? 24 : 14
        let span = max(interval.duration, 1)
        let bucketDuration = span / Double(bucketCount)
        var buckets = Array(repeating: UsageBytes.zero, count: bucketCount)
        for sample in samples {
            let offset = sample.endedAt.timeIntervalSince(interval.start)
            let index = min(max(Int(offset / bucketDuration), 0), bucketCount - 1)
            buckets[index] += sample.bytes
        }
        return buckets.enumerated().map { index, bytes in
            let date = interval.start.addingTimeInterval(Double(index) * bucketDuration)
            return UsageChartPoint(
                id: date,
                date: date,
                downloaded: Double(bytes.downloadedBytes),
                uploaded: Double(bytes.uploadedBytes)
            )
        }
    }

    public var applicationSamplingStatusText: String {
        switch applicationSamplingState {
        case .stopped: "已暂停"
        case .starting:
            applicationSamplingMode == .precise ? "正在启动精细统计" : "正在启动统计"
        case .running:
            applicationSamplingMode == .precise ? "精细统计中" : "正在统计"
        case .failed: "统计异常，正在自动重试"
        }
    }

    public var isApplicationSamplingActive: Bool {
        applicationSamplingState == .starting || applicationSamplingState == .running
    }

    public var isApplicationSamplingRequested: Bool {
        applicationSampler != nil && applicationSamplingEnabled
    }

    public var trackedApplicationCount: Int {
        Set(applicationTotals.map(\.applicationIdentifier)).count
    }

    public var launchAtLoginEnabled: Bool { launchAtLoginState == .enabled }

    public var launchAtLoginStatusText: String {
        switch launchAtLoginState {
        case .enabled: "已启用"
        case .notRegistered: "未启用"
        case .requiresApproval: "等待在系统设置中批准"
        case .notFound: "请先将 WiFiUsage 移到“应用程序”文件夹"
        }
    }

    public func bootstrap() async {
        do {
            let applicationSupport = FileManager.default.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
            ).first ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support", isDirectory: true)
            let databaseURL = applicationSupport
                .appendingPathComponent(
                    runtimeConfiguration.applicationSupportDirectory,
                    isDirectory: true
                )
                .appendingPathComponent(Self.databaseFileName, isDirectory: false)
            let repository = try SQLiteUsageRepository(url: databaseURL)
            self.repository = repository
            repositoryReady = true
            if runtimeConfiguration.allowsLegacyDatabaseImport {
                await importLegacyDatabaseIfPresent(using: repository)
            }
            try? await repository.deleteSamples(
                endingBefore: Calendar.current.date(byAdding: .day, value: -400, to: Date()) ?? .distantPast
            )
            await refreshWiFiStatus()
            startWiFiMonitoring()
            await refresh()
            await startSampling()
            if applicationSamplingEnabled {
                await startApplicationSampling()
            }
            refreshLaunchAtLogin()
            startApplicationFlushLoop()
        } catch {
            repositoryReady = false
            errorMessage = "本地数据暂时无法读取，请重新打开应用后再试。"
            NSLog("WiFiUsage bootstrap failed: %@", error.localizedDescription)
            refreshLaunchAtLogin()
        }
    }

    public func refresh() async {
        let generation = refreshGeneration
        let applicationRevision = applicationDataRevision
        guard let repository else { return }
        let queryInterval = interval
        do {
            let storedPhysical = try await repository.physicalSamples(in: queryInterval)
            let storedApps = try await repository.applicationTotals(in: queryInterval)
            let storedNetworks = try await repository.knownWiFiNetworks()
            let storedPlans = try await repository.plans()
            let storedAssignments = try await repository.wifiPlanAssignments()
            guard generation == refreshGeneration else { return }
            guard applicationRevision == applicationDataRevision else {
                Task { [weak self] in
                    await self?.refresh()
                }
                return
            }
            let livePhysicalByID = Dictionary(uniqueKeysWithValues: physicalSamples.map { ($0.id, $0) })
            var mergedPhysical = Dictionary(uniqueKeysWithValues: storedPhysical.map { ($0.id, $0) })
            for (id, sample) in livePhysicalByID where sample.endedAt > queryInterval.start && sample.endedAt <= queryInterval.end {
                mergedPhysical[id] = sample
            }
            physicalSamples = mergedPhysical.values.sorted { $0.startedAt < $1.startedAt }
            applicationTotals = mergingPendingUsage(into: storedApps)
            knownWiFiNetworks = mergeKnownNetworks(storedNetworks)
            plans = storedPlans
            let validPlanIDs = Set(storedPlans.map(\.id))
            wifiPlanAssignments = Dictionary(
                uniqueKeysWithValues: storedAssignments.compactMap { assignment in
                    guard validPlanIDs.contains(assignment.planID) else { return nil }
                    return (assignment.networkID, assignment.planID)
                }
            )
            lastUpdated = physicalSamples.map(\.endedAt).max()
            errorMessage = nil
        } catch {
            errorMessage = "数据暂时无法刷新，请稍后再试。"
            NSLog("WiFiUsage refresh failed: %@", error.localizedDescription)
        }
    }

    public func startSampling() async {
        guard !isSampling, let repository else { return }
        do {
            let sampler = try PhysicalWiFiSampler(networkResolver: networkResolver) { [weak self] sample in
                try await repository.save(physicalSample: sample)
                await MainActor.run {
                    guard let self else { return }
                    self.lastUpdated = sample.endedAt
                    if sample.endedAt >= self.interval.start {
                        self.physicalSamples.append(sample)
                    }
                }
            }
            self.sampler = sampler
            isSampling = true
            await sampler.start()
        } catch {
            errorMessage = "Wi-Fi 用量暂时无法记录，请稍后再试。"
            NSLog("WiFiUsage physical sampling failed: %@", error.localizedDescription)
        }
    }

    public func requestSSIDAccess() {
        guard runtimeConfiguration.allowsLocationSSIDAccess else { return }
        NSApp.activate(ignoringOtherApps: true)
        networkResolver.requestSSIDAuthorization()
        Task { [weak self] in
            await self?.refreshWiFiStatus()
        }
    }

    public func openWiFiNameSettings() {
        guard runtimeConfiguration.allowsLocationSSIDAccess else { return }
        guard let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?Privacy_LocationServices"
        ) else { return }
        NSWorkspace.shared.open(url)
    }

    @discardableResult
    public func assignPlan(_ planID: UUID?, toWiFiNetwork networkID: String) async -> Bool {
        guard let repository else {
            errorMessage = "本地数据暂不可用，套餐设置未保存。"
            return false
        }
        guard let network = networkOptions.first(where: { $0.key == networkID }),
              network.isIdentified else {
            errorMessage = runtimeConfiguration.isPublicDistribution
                ? "连接 Wi-Fi 并等待自动识别后，再设置套餐。"
                : "请先允许识别 Wi-Fi 名称，再设置套餐。"
            return false
        }
        if let planID, !plans.contains(where: { $0.id == planID }) {
            errorMessage = "所选套餐已不存在，请刷新后重试。"
            return false
        }
        do {
            if let knownNetwork = knownWiFiNetworks.first(where: { $0.id == networkID }) {
                try await repository.save(wifiNetwork: knownNetwork)
            } else if let identity = currentWiFiNetwork,
                      identity.networkID == networkID {
                try await repository.save(
                    wifiNetwork: KnownWiFiNetwork(identity: identity)
                )
            }
            try await repository.setPlan(planID, forWiFiNetwork: networkID)
            wifiPlanAssignments[networkID] = planID
            errorMessage = nil
            return true
        } catch {
            errorMessage = "套餐设置暂时无法保存，请稍后再试。"
            NSLog("WiFiUsage plan assignment failed: %@", error.localizedDescription)
            return false
        }
    }

    @discardableResult
    public func savePlan(
        name: String,
        currencyCode: String,
        basePrice: Decimal,
        downloadGB: Double?,
        uploadGB: Double?,
        downloadOverage: Decimal,
        uploadOverage: Decimal
    ) async -> Bool {
        guard let repository else {
            errorMessage = "本地数据暂不可用，套餐未保存。"
            return false
        }
        let plan = UsagePlan(
            name: name.trimmingCharacters(in: .whitespacesAndNewlines),
            currencyCode: currencyCode.uppercased(),
            basePrice: basePrice,
            download: DirectionalDataPlan(
                includedBytes: downloadGB.map(Self.bytesFromGigabytes),
                overagePricePerGigabyte: downloadOverage
            ),
            upload: DirectionalDataPlan(
                includedBytes: uploadGB.map(Self.bytesFromGigabytes),
                overagePricePerGigabyte: uploadOverage
            )
        )
        do {
            try await repository.save(plan: plan)
            plans.append(plan)
            errorMessage = nil
            return true
        } catch {
            errorMessage = "套餐暂时无法保存，请稍后再试。"
            NSLog("WiFiUsage save plan failed: %@", error.localizedDescription)
            return false
        }
    }

    public var applicationSamplingEnabled: Bool {
        let stored = preferences.object(forKey: Self.applicationSamplingEnabledKey)
        return stored as? Bool ?? true
    }

    public func startApplicationSampling() async {
        guard repositoryReady else { return }
        preferences.set(true, forKey: Self.applicationSamplingEnabledKey)
        applicationSamplingError = nil

        if applicationSampler == nil {
            applicationSampler = ProcessNetworkSampler(
                mode: applicationSamplingMode,
                deltaHandler: { [weak self] deltas in
                    guard let self else { return }
                    await self.recordApplicationDeltas(deltas)
                },
                stateHandler: { [weak self] state in
                    await MainActor.run {
                        self?.applicationSamplingState = state
                        if case .failed(let message) = state {
                            self?.applicationSamplingError = message
                        } else if state == .running {
                            self?.applicationSamplingError = nil
                        }
                    }
                }
            )
        }
        await applicationSampler?.start()
    }

    public func retryApplicationSampling() async {
        guard repositoryReady,
              !isRetryingApplicationSampling,
              !isChangingApplicationSamplingMode else {
            return
        }
        isRetryingApplicationSampling = true
        defer { isRetryingApplicationSampling = false }
        await applicationSampler?.stop()
        applicationSampler = nil
        await startApplicationSampling()
    }

    public func setApplicationSamplingMode(_ mode: ApplicationSamplingMode) async {
        guard mode != applicationSamplingMode, !isChangingApplicationSamplingMode else { return }
        isChangingApplicationSamplingMode = true
        defer { isChangingApplicationSamplingMode = false }

        preciseModeTask?.cancel()
        preciseModeTask = nil
        preciseSamplingEndsAt = nil
        let shouldRestart = applicationSamplingEnabled
        await applicationSampler?.stop()
        applicationSampler = nil
        await flushPendingApplicationUsage()
        applicationSamplingMode = mode

        if mode == .precise {
            let endDate = Date().addingTimeInterval(Self.preciseSamplingDuration)
            preciseSamplingEndsAt = endDate
            preciseModeTask = Task { [weak self] in
                do {
                    try await Task.sleep(for: .seconds(Self.preciseSamplingDuration))
                } catch {
                    return
                }
                await self?.setApplicationSamplingMode(.balanced)
            }
        }
        if shouldRestart {
            await startApplicationSampling()
        }
    }

    public func stopApplicationSampling() async {
        preferences.set(false, forKey: Self.applicationSamplingEnabledKey)
        await applicationSampler?.stop()
        await flushPendingApplicationUsage()
    }

    public func prepareForTermination() async {
        applicationFlushTask?.cancel()
        preciseModeTask?.cancel()
        networkMonitorTask?.cancel()
        await sampler?.stop()
        sampler = nil
        isSampling = false
        await applicationSampler?.stop()
        applicationSampler = nil
        await flushPendingApplicationUsage()
    }

    public func refreshLaunchAtLogin() {
        launchAtLoginState = launchAtLoginManager.state
    }

    public func setLaunchAtLogin(_ enabled: Bool) async {
        guard !isChangingLaunchAtLogin else { return }
        isChangingLaunchAtLogin = true
        defer {
            isChangingLaunchAtLogin = false
            refreshLaunchAtLogin()
        }
        do {
            try launchAtLoginManager.setEnabled(enabled)
            errorMessage = nil
        } catch {
            errorMessage = "登录时启动设置未能更新，请稍后重试。"
            NSLog("WiFiUsage launch-at-login update failed: %@", error.localizedDescription)
        }
    }

    public func openLoginItemsSettings() {
        launchAtLoginManager.openSystemSettings()
    }

    public func revealCurrentApplication() {
        NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL])
    }

    public func openApplicationsFolder() {
        NSWorkspace.shared.open(URL(fileURLWithPath: "/Applications", isDirectory: true))
    }

    public func refreshWiFiStatus() async {
        wifiStatusGeneration &+= 1
        let generation = wifiStatusGeneration
        let resolvedNetwork = await networkResolver.currentNetwork()
        guard !Task.isCancelled, generation == wifiStatusGeneration else { return }

        let previousNetwork = currentWiFiNetwork
        let previouslyIdentifiedCurrentID = lastIdentifiedCurrentNetworkID
        wifiNameAccessState = runtimeConfiguration.allowsLocationSSIDAccess
            ? networkResolver.wifiNameAccessState
            : .notRequired
        currentWiFiNetwork = resolvedNetwork

        if previousNetwork != resolvedNetwork {
            await sampler?.resetBaseline()
            guard !Task.isCancelled, generation == wifiStatusGeneration else { return }
        }

        if let resolvedNetwork,
           let ssid = resolvedNetwork.ssid,
           !ssid.isEmpty {
            let networkID = resolvedNetwork.networkID
            if !didInitializeNetworkSelection {
                didInitializeNetworkSelection = true
                selectedNetworkKey = networkID
            } else if let previouslyIdentifiedCurrentID,
                      selectedNetworkKey == previouslyIdentifiedCurrentID,
                      previouslyIdentifiedCurrentID != networkID {
                selectedNetworkKey = networkID
            }
            lastIdentifiedCurrentNetworkID = networkID
        }

        guard let resolvedNetwork else {
            registeredCurrentNetworkID = nil
            return
        }

        let observedAt = Date()
        let observedNetwork = KnownWiFiNetwork(
            identity: resolvedNetwork,
            observedAt: observedAt
        )
        knownWiFiNetworks = mergeKnownNetworks(knownWiFiNetworks + [observedNetwork])

        guard let repository else { return }
        guard registeredCurrentNetworkID != observedNetwork.id else { return }
        registeredCurrentNetworkID = observedNetwork.id
        do {
            try await repository.save(wifiNetwork: observedNetwork)
        } catch {
            NSLog("WiFiUsage could not save the current Wi-Fi: %@", error.localizedDescription)
            if registeredCurrentNetworkID == observedNetwork.id {
                registeredCurrentNetworkID = nil
            }
        }
    }

    private func startWiFiMonitoring() {
        networkMonitorTask?.cancel()
        networkMonitorTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .seconds(2))
                } catch {
                    return
                }
                guard let self else { return }
                await self.refreshWiFiStatus()
            }
        }
    }

    private func mergeKnownNetworks(
        _ networks: [KnownWiFiNetwork]
    ) -> [KnownWiFiNetwork] {
        var networksByID: [String: KnownWiFiNetwork] = [:]
        for network in networks {
            if let existing = networksByID[network.id] {
                networksByID[network.id] = KnownWiFiNetwork(
                    id: network.id,
                    ssid: network.ssid ?? existing.ssid,
                    interfaceName: network.interfaceName,
                    firstSeenAt: min(existing.firstSeenAt, network.firstSeenAt),
                    lastSeenAt: max(existing.lastSeenAt, network.lastSeenAt)
                )
            } else {
                networksByID[network.id] = network
            }
        }
        if let currentWiFiNetwork {
            let live = KnownWiFiNetwork(identity: currentWiFiNetwork)
            if let existing = networksByID[live.id] {
                networksByID[live.id] = KnownWiFiNetwork(
                    id: live.id,
                    ssid: live.ssid ?? existing.ssid,
                    interfaceName: live.interfaceName,
                    firstSeenAt: min(existing.firstSeenAt, live.firstSeenAt),
                    lastSeenAt: max(existing.lastSeenAt, live.lastSeenAt)
                )
            } else {
                networksByID[live.id] = live
            }
        }
        return networksByID.values.sorted { $0.lastSeenAt > $1.lastSeenAt }
    }

    private func scheduleRefresh() {
        refreshGeneration &+= 1
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            guard let self else { return }
            await self.refresh()
        }
    }

    private func recordApplicationDeltas(_ deltas: [ProcessNetworkDelta]) {
        var grouped: [String: PendingApplicationUsage] = [:]

        for delta in deltas {
            let application = resolveApplication(
                processIdentifier: delta.processIdentifier,
                fallbackName: delta.processName
            )
            applicationMetadata[application.identifier] = application.metadata

            if var existing = grouped[application.identifier] {
                existing.startedAt = min(existing.startedAt, delta.startedAt)
                existing.endedAt = max(existing.endedAt, delta.endedAt)
                existing.bytes += delta.bytes
                grouped[application.identifier] = existing
            } else {
                grouped[application.identifier] = PendingApplicationUsage(
                    startedAt: delta.startedAt,
                    endedAt: delta.endedAt,
                    bytes: delta.bytes
                )
            }
        }

        for (identifier, usage) in grouped where usage.bytes != .zero {
            mergePendingUsage(identifier: identifier, usage: usage)
            mergeLiveApplicationTotal(identifier: identifier, bytes: usage.bytes)
            lastApplicationSampleAt = max(lastApplicationSampleAt ?? .distantPast, usage.endedAt)
        }
    }

    private func mergePendingUsage(identifier: String, usage: PendingApplicationUsage) {
        if var existing = pendingApplicationUsage[identifier] {
            existing.startedAt = min(existing.startedAt, usage.startedAt)
            existing.endedAt = max(existing.endedAt, usage.endedAt)
            existing.bytes += usage.bytes
            pendingApplicationUsage[identifier] = existing
        } else {
            pendingApplicationUsage[identifier] = usage
        }
    }

    private func mergeLiveApplicationTotal(identifier: String, bytes: UsageBytes) {
        if let index = applicationTotals.firstIndex(where: {
            $0.applicationIdentifier == identifier && $0.carrier == .wifi
        }) {
            applicationTotals[index].bytes += bytes
        } else {
            applicationTotals.append(ApplicationUsageTotal(
                applicationIdentifier: identifier,
                carrier: .wifi,
                bytes: bytes
            ))
        }
    }

    private func flushPendingApplicationUsage() async {
        guard let repository, !pendingApplicationUsage.isEmpty else { return }
        applicationDataRevision &+= 1
        let pending = pendingApplicationUsage
        pendingApplicationUsage.removeAll(keepingCapacity: true)

        let buckets = pending.map { identifier, usage in
            let bucketTimestamp = floor(
                usage.endedAt.timeIntervalSince1970 / Self.applicationBucketDuration
            ) * Self.applicationBucketDuration
            return ApplicationUsageBucket(
                applicationIdentifier: identifier,
                carrier: .wifi,
                bucketStart: Date(timeIntervalSince1970: bucketTimestamp),
                endedAt: usage.endedAt,
                bytes: usage.bytes
            )
        }

        do {
            try await repository.save(applicationBuckets: buckets)
            applicationSamplingError = nil
        } catch {
            for (identifier, usage) in pending {
                mergePendingUsage(identifier: identifier, usage: usage)
            }
            applicationSamplingError = "应用用量暂时无法保存，稍后会自动重试。"
            NSLog("WiFiUsage application usage save failed: %@", error.localizedDescription)
        }
        applicationDataRevision &+= 1
    }

    private func mergingPendingUsage(
        into storedTotals: [ApplicationUsageTotal]
    ) -> [ApplicationUsageTotal] {
        var totals = storedTotals
        for (identifier, usage) in pendingApplicationUsage {
            if let index = totals.firstIndex(where: {
                $0.applicationIdentifier == identifier && $0.carrier == .wifi
            }) {
                totals[index].bytes += usage.bytes
            } else {
                totals.append(ApplicationUsageTotal(
                    applicationIdentifier: identifier,
                    carrier: .wifi,
                    bytes: usage.bytes
                ))
            }
        }
        return totals
    }

    private func resolveApplication(
        processIdentifier: Int32,
        fallbackName: String
    ) -> ResolvedApplication {
        var candidatePID = processIdentifier
        var seen: Set<Int32> = []
        var fallbackApplication: ResolvedApplication?

        for _ in 0..<8 where candidatePID > 1 && seen.insert(candidatePID).inserted {
            if let running = NSRunningApplication(processIdentifier: candidatePID),
               let rawIdentifier = running.bundleIdentifier {
                let identifier = Self.normalizedBundleIdentifier(rawIdentifier)
                let appURL = running.bundleURL
                    ?? NSWorkspace.shared.urlForApplication(withBundleIdentifier: identifier)
                let metadata = ApplicationMetadata(
                    name: running.localizedName
                        ?? appURL.flatMap(Self.bundleDisplayName(at:))
                        ?? Self.displayName(for: identifier),
                    iconPath: appURL?.path
                )
                let resolved = ResolvedApplication(identifier: identifier, metadata: metadata)
                if running.activationPolicy != .prohibited {
                    return resolved
                }
                fallbackApplication = fallbackApplication ?? resolved
            }

            var parentIdentifier: Int32 = 0
            var startSeconds: Int64 = 0
            var startMicroseconds: Int32 = 0
            guard WUCopyProcessIdentity(
                candidatePID,
                &parentIdentifier,
                &startSeconds,
                &startMicroseconds
            ) == 0, parentIdentifier > 0, parentIdentifier != candidatePID else {
                break
            }
            candidatePID = parentIdentifier
        }

        if let fallbackApplication {
            return fallbackApplication
        }
        let cleanedName = fallbackName.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = cleanedName.isEmpty ? "未知进程" : cleanedName
        return ResolvedApplication(
            identifier: "process:\(name)",
            metadata: ApplicationMetadata(name: name, iconPath: nil)
        )
    }

    private static func normalizedBundleIdentifier(_ identifier: String) -> String {
        guard let helperRange = identifier.range(
            of: ".helper",
            options: [.caseInsensitive]
        ) else {
            return identifier
        }
        return String(identifier[..<helperRange.lowerBound])
    }

    private static func bundleDisplayName(at url: URL) -> String? {
        guard let bundle = Bundle(url: url) else {
            return FileManager.default.displayName(atPath: url.path)
        }
        return bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
            ?? bundle.object(forInfoDictionaryKey: "CFBundleName") as? String
            ?? FileManager.default.displayName(atPath: url.path)
    }

    private func startApplicationFlushLoop() {
        applicationFlushTask?.cancel()
        applicationFlushTask = Task { [weak self] in
            var tick = 0
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .seconds(10))
                } catch {
                    return
                }
                guard let self else { return }
                await self.flushPendingApplicationUsage()
                tick += 1
                if tick.isMultiple(of: 6) {
                    await self.refresh()
                }
            }
        }
    }

    private func importLegacyDatabaseIfPresent(
        using repository: SQLiteUsageRepository
    ) async {
        let sourceURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(
                "Library/Group Containers/\(Self.legacyAppGroupIdentifier)",
                isDirectory: true
            )
            .appendingPathComponent(Self.databaseFileName)
        guard FileManager.default.fileExists(atPath: sourceURL.path) else { return }

        do {
            _ = try await repository.importLegacyDatabase(at: sourceURL)
        } catch {
            // No marker is written on failure, so the next launch retries safely.
            NSLog(
                "Legacy WiFiUsage database migration failed: %@",
                error.localizedDescription
            )
        }
    }

    private func metadata(for identifier: String) -> ApplicationMetadata {
        if let metadata = applicationMetadata[identifier] {
            return metadata
        }
        if identifier.hasPrefix("process:") {
            return ApplicationMetadata(
                name: String(identifier.dropFirst("process:".count)),
                iconPath: nil
            )
        }
        if let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: identifier) {
            return ApplicationMetadata(
                name: Self.bundleDisplayName(at: appURL) ?? Self.displayName(for: identifier),
                iconPath: appURL.path
            )
        }
        return ApplicationMetadata(name: Self.displayName(for: identifier), iconPath: nil)
    }

    private static func displayName(for identifier: String) -> String {
        let known = [
            "com.apple.Safari": "Safari",
            "com.apple.Music": "音乐",
            "com.apple.AppStore": "App Store",
            "com.tinyspeck.slackmacgap": "Slack",
            "com.microsoft.VSCode": "Visual Studio Code",
            "com.apple.cloudphotosd": "iCloud 照片"
        ]
        return known[identifier] ?? identifier.split(separator: ".").last.map(String.init) ?? identifier
    }

    private static func bytesFromGigabytes(_ value: Double) -> UInt64 {
        UInt64(max(0, value) * 1_000_000_000)
    }
}
