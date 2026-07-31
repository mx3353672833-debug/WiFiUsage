import Foundation

public enum UsagePeriodError: Error, Equatable, Sendable {
    case invalidCustomRange
    case invalidBillingCycleStartDay
    case calendarCalculationFailed
}

/// A user-facing period that can be resolved with an explicit calendar.
/// Date intervals are half-open: `start <= date < end`.
public enum UsagePeriod: Codable, Hashable, Sendable {
    case day(containing: Date)
    case week(containing: Date)
    case month(containing: Date)
    case billingCycle(containing: Date, startDay: Int)
    case custom(start: Date, end: Date)

    public func dateInterval(calendar: Calendar = .current) throws -> DateInterval {
        switch self {
        case let .day(date):
            guard let interval = calendar.dateInterval(of: .day, for: date) else {
                throw UsagePeriodError.calendarCalculationFailed
            }
            return interval

        case let .week(date):
            guard let interval = calendar.dateInterval(of: .weekOfYear, for: date) else {
                throw UsagePeriodError.calendarCalculationFailed
            }
            return interval

        case let .month(date):
            guard let interval = calendar.dateInterval(of: .month, for: date) else {
                throw UsagePeriodError.calendarCalculationFailed
            }
            return interval

        case let .billingCycle(date, startDay):
            guard (1...31).contains(startDay) else {
                throw UsagePeriodError.invalidBillingCycleStartDay
            }
            let thisMonthStart = try cycleStart(inMonthContaining: date, day: startDay, calendar: calendar)
            let start: Date
            if date >= thisMonthStart {
                start = thisMonthStart
            } else {
                guard let previousMonth = calendar.date(byAdding: .month, value: -1, to: date) else {
                    throw UsagePeriodError.calendarCalculationFailed
                }
                start = try cycleStart(inMonthContaining: previousMonth, day: startDay, calendar: calendar)
            }
            guard let followingMonth = calendar.date(byAdding: .month, value: 1, to: start) else {
                throw UsagePeriodError.calendarCalculationFailed
            }
            let end = try cycleStart(inMonthContaining: followingMonth, day: startDay, calendar: calendar)
            return DateInterval(start: start, end: end)

        case let .custom(start, end):
            guard end > start else { throw UsagePeriodError.invalidCustomRange }
            return DateInterval(start: start, end: end)
        }
    }

    public func contains(_ date: Date, calendar: Calendar = .current) throws -> Bool {
        let interval = try dateInterval(calendar: calendar)
        return date >= interval.start && date < interval.end
    }

    private func cycleStart(inMonthContaining date: Date, day: Int, calendar: Calendar) throws -> Date {
        guard let monthInterval = calendar.dateInterval(of: .month, for: date),
              let dayRange = calendar.range(of: .day, in: .month, for: monthInterval.start) else {
            throw UsagePeriodError.calendarCalculationFailed
        }
        var components = calendar.dateComponents([.era, .year, .month], from: monthInterval.start)
        components.day = min(day, dayRange.count)
        components.hour = 0
        components.minute = 0
        components.second = 0
        components.nanosecond = 0
        guard let result = calendar.date(from: components) else {
            throw UsagePeriodError.calendarCalculationFailed
        }
        return result
    }
}
