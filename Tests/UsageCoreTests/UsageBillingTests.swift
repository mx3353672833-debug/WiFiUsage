import Foundation
import XCTest
@testable import UsageCore

final class UsageBillingTests: XCTestCase {
    func testDirectionalOverageUsesDecimalArithmetic() {
        let plan = UsagePlan(
            name: "Metered",
            currencyCode: "CNY",
            basePrice: Decimal(string: "9.90")!,
            download: DirectionalDataPlan(
                includedBytes: 1_000_000_000,
                overagePricePerGigabyte: Decimal(string: "2.50")!
            ),
            upload: DirectionalDataPlan(
                includedBytes: 500_000_000,
                overagePricePerGigabyte: Decimal(string: "4.00")!
            )
        )

        let cost = UsageBilling.cost(
            for: UsageBytes(downloadedBytes: 2_500_000_000, uploadedBytes: 750_000_000),
            plan: plan
        )

        XCTAssertEqual(cost.downloadOverage, Decimal(string: "3.75"))
        XCTAssertEqual(cost.uploadOverage, Decimal(string: "1.00"))
        XCTAssertEqual(cost.total, Decimal(string: "14.65"))
    }

    func testUnlimitedDirectionDoesNotCharge() {
        let plan = UsagePlan(
            name: "Unlimited upload",
            currencyCode: "USD",
            download: DirectionalDataPlan(includedBytes: 0, overagePricePerGigabyte: 1),
            upload: .unlimited
        )
        let cost = UsageBilling.cost(
            for: UsageBytes(downloadedBytes: 1_000_000_000, uploadedBytes: .max),
            plan: plan
        )

        XCTAssertEqual(cost.downloadOverage, 1)
        XCTAssertEqual(cost.uploadOverage, 0)
    }

    func testApplicationAllocationSeparatesDirectionsAndUntrackedUsage() {
        let bill = UsageCostBreakdown(
            currencyCode: "USD",
            basePrice: 10,
            downloadOverage: 20,
            uploadOverage: 30
        )
        let allocation = ApplicationCostAllocator.allocate(
            applications: [
                ApplicationUsageTotal(
                    applicationIdentifier: "video",
                    bytes: UsageBytes(downloadedBytes: 250, uploadedBytes: 0)
                ),
                ApplicationUsageTotal(
                    applicationIdentifier: "backup",
                    bytes: UsageBytes(downloadedBytes: 0, uploadedBytes: 500)
                )
            ],
            physicalUsage: UsageBytes(downloadedBytes: 1_000, uploadedBytes: 1_000),
            cost: bill
        )

        let video = allocation.applications.first { $0.applicationIdentifier == "video" }
        let backup = allocation.applications.first { $0.applicationIdentifier == "backup" }
        XCTAssertEqual(video?.estimatedCost, Decimal(string: "6.25"))
        XCTAssertEqual(backup?.estimatedCost, Decimal(string: "17.5"))
        XCTAssertEqual(allocation.unallocatedCost + allocation.applications.reduce(0) { $0 + $1.estimatedCost }, 60)
    }

    func testAllocationNeverExceedsBillWhenTrackedCountersAreHigher() {
        let bill = UsageCostBreakdown(currencyCode: "USD", basePrice: 0, downloadOverage: 10, uploadOverage: 0)
        let allocation = ApplicationCostAllocator.allocate(
            applications: [
                ApplicationUsageTotal(applicationIdentifier: "a", bytes: UsageBytes(downloadedBytes: 800)),
                ApplicationUsageTotal(applicationIdentifier: "b", bytes: UsageBytes(downloadedBytes: 800))
            ],
            physicalUsage: UsageBytes(downloadedBytes: 1_000),
            cost: bill
        )
        XCTAssertEqual(allocation.applications.reduce(0) { $0 + $1.estimatedCost }, 10)
        XCTAssertEqual(allocation.unallocatedCost, 0)
    }
}
