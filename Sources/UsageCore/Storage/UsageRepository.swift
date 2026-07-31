import Foundation

public protocol UsageRepository: Sendable {
    func save(physicalSample: PhysicalUsageSample) async throws
    func save(applicationSample: ApplicationUsageSample) async throws
    func save(applicationSamples: [ApplicationUsageSample]) async throws
    func save(applicationBuckets: [ApplicationUsageBucket]) async throws
    func save(wifiNetwork: KnownWiFiNetwork) async throws
    func save(plan: UsagePlan) async throws
    func setPlan(_ planID: UUID?, forWiFiNetwork networkID: String) async throws
    func physicalSamples(in interval: DateInterval) async throws -> [PhysicalUsageSample]
    func applicationTotals(in interval: DateInterval) async throws -> [ApplicationUsageTotal]
    func knownWiFiNetworks() async throws -> [KnownWiFiNetwork]
    func plans() async throws -> [UsagePlan]
    func wifiPlanAssignments() async throws -> [WiFiPlanAssignment]
    func deleteSamples(endingBefore date: Date) async throws
}

public extension UsageRepository {
    func save(applicationSamples: [ApplicationUsageSample]) async throws {
        for sample in applicationSamples {
            try await save(applicationSample: sample)
        }
    }

    func save(applicationBuckets: [ApplicationUsageBucket]) async throws {
        for bucket in applicationBuckets {
            try await save(applicationSample: ApplicationUsageSample(
                applicationIdentifier: bucket.applicationIdentifier,
                carrier: bucket.carrier,
                startedAt: bucket.bucketStart,
                endedAt: bucket.endedAt,
                bytes: bucket.bytes
            ))
        }
    }

    func physicalTotal(in interval: DateInterval) async throws -> UsageBytes {
        try await physicalSamples(in: interval).reduce(.zero) { $0 + $1.bytes }
    }
}
