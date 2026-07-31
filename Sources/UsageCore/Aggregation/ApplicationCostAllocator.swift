import Foundation

public struct EstimatedApplicationCost: Codable, Hashable, Sendable {
    public let applicationIdentifier: String
    public let bytes: UsageBytes
    public let estimatedCost: Decimal

    public init(applicationIdentifier: String, bytes: UsageBytes, estimatedCost: Decimal) {
        self.applicationIdentifier = applicationIdentifier
        self.bytes = bytes
        self.estimatedCost = estimatedCost
    }
}

public struct ApplicationCostAllocation: Codable, Hashable, Sendable {
    public let applications: [EstimatedApplicationCost]
    public let unallocatedCost: Decimal

    public init(applications: [EstimatedApplicationCost], unallocatedCost: Decimal) {
        self.applications = applications
        self.unallocatedCost = unallocatedCost
    }
}

public enum ApplicationCostAllocator {
    /// Allocates directional overage independently and base price by total bytes.
    /// Physical totals remain the denominator when app telemetry is incomplete, leaving
    /// the uncovered share in `unallocatedCost`. If app telemetry exceeds physical totals,
    /// the app sum is used to ensure estimates never exceed the bill.
    public static func allocate(
        applications: [ApplicationUsageTotal],
        physicalUsage: UsageBytes,
        cost: UsageCostBreakdown
    ) -> ApplicationCostAllocation {
        let combined = Dictionary(grouping: applications, by: \.applicationIdentifier)
            .map { identifier, values in
                ApplicationUsageTotal(
                    applicationIdentifier: identifier,
                    bytes: values.reduce(.zero) { $0 + $1.bytes }
                )
            }
            .sorted { $0.applicationIdentifier < $1.applicationIdentifier }

        let trackedDownload = combined.reduce(UInt64(0)) { saturatedSum($0, $1.bytes.downloadedBytes) }
        let trackedUpload = combined.reduce(UInt64(0)) { saturatedSum($0, $1.bytes.uploadedBytes) }
        let trackedTotal = combined.reduce(UInt64(0)) { saturatedSum($0, $1.bytes.totalBytes) }

        let downloadDenominator = max(physicalUsage.downloadedBytes, trackedDownload)
        let uploadDenominator = max(physicalUsage.uploadedBytes, trackedUpload)
        let totalDenominator = max(physicalUsage.totalBytes, trackedTotal)

        let estimates = combined.map { app in
            let downloadShare = share(app.bytes.downloadedBytes, of: downloadDenominator)
            let uploadShare = share(app.bytes.uploadedBytes, of: uploadDenominator)
            let baseShare = share(app.bytes.totalBytes, of: totalDenominator)
            return EstimatedApplicationCost(
                applicationIdentifier: app.applicationIdentifier,
                bytes: app.bytes,
                estimatedCost: cost.downloadOverage * downloadShare
                    + cost.uploadOverage * uploadShare
                    + cost.basePrice * baseShare
            )
        }

        let allocated = estimates.reduce(Decimal.zero) { $0 + $1.estimatedCost }
        return ApplicationCostAllocation(
            applications: estimates,
            unallocatedCost: max(Decimal.zero, cost.total - allocated)
        )
    }

    private static func share(_ numerator: UInt64, of denominator: UInt64) -> Decimal {
        guard numerator > 0, denominator > 0 else { return 0 }
        return UsageBilling.decimal(numerator) / UsageBilling.decimal(denominator)
    }

    private static func saturatedSum(_ lhs: UInt64, _ rhs: UInt64) -> UInt64 {
        let (sum, overflow) = lhs.addingReportingOverflow(rhs)
        return overflow ? .max : sum
    }
}
