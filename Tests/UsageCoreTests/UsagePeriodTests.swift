import Foundation
import XCTest
@testable import UsageCore

final class UsagePeriodTests: XCTestCase {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "en_US_POSIX")
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        calendar.firstWeekday = 2
        return calendar
    }

    func testMonthUsesHalfOpenCalendarRange() throws {
        let date = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 2, day: 14, hour: 12)))
        let interval = try UsagePeriod.month(containing: date).dateInterval(calendar: calendar)

        XCTAssertEqual(calendar.dateComponents([.year, .month, .day], from: interval.start),
                       DateComponents(year: 2026, month: 2, day: 1))
        XCTAssertEqual(calendar.dateComponents([.year, .month, .day], from: interval.end),
                       DateComponents(year: 2026, month: 3, day: 1))
        XCTAssertTrue(try UsagePeriod.month(containing: date).contains(interval.start, calendar: calendar))
        XCTAssertFalse(try UsagePeriod.month(containing: date).contains(interval.end, calendar: calendar))
    }

    func testBillingCycleClampsDayToShortMonth() throws {
        let date = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 2, day: 28, hour: 20)))
        let interval = try UsagePeriod.billingCycle(containing: date, startDay: 31)
            .dateInterval(calendar: calendar)

        XCTAssertEqual(calendar.dateComponents([.year, .month, .day], from: interval.start),
                       DateComponents(year: 2026, month: 2, day: 28))
        XCTAssertEqual(calendar.dateComponents([.year, .month, .day], from: interval.end),
                       DateComponents(year: 2026, month: 3, day: 31))
    }

    func testBillingCycleBeforeStartUsesPreviousMonth() throws {
        let date = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 7, day: 5)))
        let interval = try UsagePeriod.billingCycle(containing: date, startDay: 15)
            .dateInterval(calendar: calendar)

        XCTAssertEqual(calendar.dateComponents([.year, .month, .day], from: interval.start),
                       DateComponents(year: 2026, month: 6, day: 15))
        XCTAssertEqual(calendar.dateComponents([.year, .month, .day], from: interval.end),
                       DateComponents(year: 2026, month: 7, day: 15))
    }

    func testRejectsInvalidRangesAndCycleDays() {
        XCTAssertThrowsError(try UsagePeriod.custom(start: Date(), end: Date()).dateInterval())
        XCTAssertThrowsError(try UsagePeriod.billingCycle(containing: Date(), startDay: 0).dateInterval())
        XCTAssertThrowsError(try UsagePeriod.billingCycle(containing: Date(), startDay: 32).dateInterval())
    }
}
