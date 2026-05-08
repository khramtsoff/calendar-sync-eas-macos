import Foundation
import EventKit

/// Maps an `EASRecurrence` (MS-ASCAL) onto an `EKRecurrenceRule`.
///
/// Coverage:
///   Type 0 -> daily, Type 1 -> weekly, Type 2 -> monthly (DOM),
///   Type 3 -> monthly (Nth weekday), Type 5 -> yearly (DOM/MOY),
///   Type 6 -> yearly (Nth weekday in month).
enum RecurrenceMapper {
    static func map(_ r: EASRecurrence) -> EKRecurrenceRule? {
        let interval = max(r.interval, 1)
        let end = makeEnd(from: r)

        switch r.type {
        case 0:
            return EKRecurrenceRule(recurrenceWith: .daily,
                                    interval: interval,
                                    end: end)

        case 1:
            let days = mapDayOfWeekBitmask(r.dayOfWeek)
            return EKRecurrenceRule(recurrenceWith: .weekly,
                                    interval: interval,
                                    daysOfTheWeek: days.isEmpty ? nil : days,
                                    daysOfTheMonth: nil,
                                    monthsOfTheYear: nil,
                                    weeksOfTheYear: nil,
                                    daysOfTheYear: nil,
                                    setPositions: nil,
                                    end: end)

        case 2:
            let dom = r.dayOfMonth.map { [NSNumber(value: $0)] }
            return EKRecurrenceRule(recurrenceWith: .monthly,
                                    interval: interval,
                                    daysOfTheWeek: nil,
                                    daysOfTheMonth: dom,
                                    monthsOfTheYear: nil,
                                    weeksOfTheYear: nil,
                                    daysOfTheYear: nil,
                                    setPositions: nil,
                                    end: end)

        case 3:
            let days = mapDayOfWeekBitmask(r.dayOfWeek)
            let week = mapWeekOfMonth(r.weekOfMonth)
            return EKRecurrenceRule(recurrenceWith: .monthly,
                                    interval: interval,
                                    daysOfTheWeek: days.isEmpty ? nil : days,
                                    daysOfTheMonth: nil,
                                    monthsOfTheYear: nil,
                                    weeksOfTheYear: nil,
                                    daysOfTheYear: nil,
                                    setPositions: week.map { [NSNumber(value: $0)] },
                                    end: end)

        case 5:
            let dom = r.dayOfMonth.map { [NSNumber(value: $0)] }
            let moy = r.monthOfYear.map { [NSNumber(value: $0)] }
            return EKRecurrenceRule(recurrenceWith: .yearly,
                                    interval: interval,
                                    daysOfTheWeek: nil,
                                    daysOfTheMonth: dom,
                                    monthsOfTheYear: moy,
                                    weeksOfTheYear: nil,
                                    daysOfTheYear: nil,
                                    setPositions: nil,
                                    end: end)

        case 6:
            let days = mapDayOfWeekBitmask(r.dayOfWeek)
            let week = mapWeekOfMonth(r.weekOfMonth)
            let moy = r.monthOfYear.map { [NSNumber(value: $0)] }
            return EKRecurrenceRule(recurrenceWith: .yearly,
                                    interval: interval,
                                    daysOfTheWeek: days.isEmpty ? nil : days,
                                    daysOfTheMonth: nil,
                                    monthsOfTheYear: moy,
                                    weeksOfTheYear: nil,
                                    daysOfTheYear: nil,
                                    setPositions: week.map { [NSNumber(value: $0)] },
                                    end: end)

        default:
            return nil
        }
    }

    private static func makeEnd(from r: EASRecurrence) -> EKRecurrenceEnd? {
        if let n = r.occurrences, n > 0 {
            return EKRecurrenceEnd(occurrenceCount: n)
        }
        if let until = r.until {
            return EKRecurrenceEnd(end: until)
        }
        return nil
    }

    /// EAS DayOfWeek bitfield: 1=Sun, 2=Mon, 4=Tue, 8=Wed, 16=Thu, 32=Fri, 64=Sat.
    /// 127 with type 3 means "weekday-of-month" - we approximate with M-F.
    private static func mapDayOfWeekBitmask(_ raw: Int?) -> [EKRecurrenceDayOfWeek] {
        guard let value = raw else { return [] }
        let weekdays: [(Int, EKWeekday)] = [
            (1, .sunday), (2, .monday), (4, .tuesday), (8, .wednesday),
            (16, .thursday), (32, .friday), (64, .saturday)
        ]
        return weekdays.compactMap { mask, day in
            (value & mask) != 0 ? EKRecurrenceDayOfWeek(day) : nil
        }
    }

    /// EAS WeekOfMonth: 1..4 = Nth, 5 = last.
    private static func mapWeekOfMonth(_ value: Int?) -> Int? {
        guard let v = value else { return nil }
        if v == 5 { return -1 }
        return v
    }
}
