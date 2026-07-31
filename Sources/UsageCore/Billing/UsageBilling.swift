import Foundation

/// Direction-specific included traffic and overage pricing.
/// `includedBytes == nil` means unlimited traffic in that direction.
public struct DirectionalDataPlan: Codable, Hashable, Sendable {
    public let includedBytes: UInt64?
    public let overagePricePerGigabyte: Decimal

    public init(includedBytes: UInt64?, overagePricePerGigabyte: Decimal) {
        self.includedBytes = includedBytes
        self.overagePricePerGigabyte = overagePricePerGigabyte
    }

    public static let unlimited = DirectionalDataPlan(includedBytes: nil, overagePricePerGigabyte: 0)
}

public struct UsagePlan: Codable, Hashable, Identifiable, Sendable {
    public let id: UUID
    public let name: String
    public let currencyCode: String
    public let basePrice: Decimal
    public let download: DirectionalDataPlan
    public let upload: DirectionalDataPlan

    public init(
        id: UUID = UUID(),
        name: String,
        currencyCode: String,
        basePrice: Decimal = 0,
        download: DirectionalDataPlan,
        upload: DirectionalDataPlan
    ) {
        self.id = id
        self.name = name
        self.currencyCode = currencyCode
        self.basePrice = basePrice
        self.download = download
        self.upload = upload
    }
}

public struct UsageCostBreakdown: Codable, Hashable, Sendable {
    public let currencyCode: String
    public let basePrice: Decimal
    public let downloadOverage: Decimal
    public let uploadOverage: Decimal

    public init(
        currencyCode: String,
        basePrice: Decimal,
        downloadOverage: Decimal,
        uploadOverage: Decimal
    ) {
        self.currencyCode = currencyCode
        self.basePrice = basePrice
        self.downloadOverage = downloadOverage
        self.uploadOverage = uploadOverage
    }

    public var total: Decimal { basePrice + downloadOverage + uploadOverage }
}

public enum UsageBilling {
    /// Calculates proportional overage with Decimal arithmetic. One GB is 1,000,000,000 bytes.
    public static func cost(
        for usage: UsageBytes,
        plan: UsagePlan,
        scale: Int = 2,
        roundingMode: Decimal.RoundingMode = .bankers
    ) -> UsageCostBreakdown {
        let download = directionalCost(
            bytes: usage.downloadedBytes,
            plan: plan.download,
            scale: scale,
            roundingMode: roundingMode
        )
        let upload = directionalCost(
            bytes: usage.uploadedBytes,
            plan: plan.upload,
            scale: scale,
            roundingMode: roundingMode
        )
        return UsageCostBreakdown(
            currencyCode: plan.currencyCode,
            basePrice: rounded(plan.basePrice, scale: scale, mode: roundingMode),
            downloadOverage: download,
            uploadOverage: upload
        )
    }

    public static func directionalCost(
        bytes: UInt64,
        plan: DirectionalDataPlan,
        scale: Int = 2,
        roundingMode: Decimal.RoundingMode = .bankers
    ) -> Decimal {
        guard let included = plan.includedBytes, bytes > included else { return 0 }
        let excess = bytes - included
        let gigabytes = decimal(excess) / Decimal(1_000_000_000)
        return rounded(gigabytes * plan.overagePricePerGigabyte, scale: scale, mode: roundingMode)
    }

    public static func rounded(
        _ value: Decimal,
        scale: Int,
        mode: Decimal.RoundingMode = .bankers
    ) -> Decimal {
        var input = value
        var output = Decimal()
        NSDecimalRound(&output, &input, max(0, scale), mode)
        return output
    }

    static func decimal(_ value: UInt64) -> Decimal {
        Decimal(string: String(value), locale: Locale(identifier: "en_US_POSIX")) ?? 0
    }
}
