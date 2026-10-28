import Foundation
import Testing
@testable import PulseCore

/// NYSE/Nasdaq full-day closures. 2026 is the reference year: New Year's Day
/// is a Thursday, Independence Day falls on a Saturday (observed Friday), and
/// Christmas is a Friday.
@Suite("US exchange holidays")
struct USHolidayCalendarTests {
    private func newYork(
        _ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int = 0
    ) throws -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = Market.us.timeZone
        return try #require(calendar.date(from: DateComponents(
            year: year, month: month, day: day, hour: hour, minute: minute
        )))
    }

    private func state(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 10) throws -> SessionState {
        TradingCalendar.state(of: .us, at: try newYork(year, month, day, hour))
    }

    @Test("Every 2026 full-day closure is closed during the regular session")
    func fullDayClosures() throws {
        let closures = [
            (1, 1),    // New Year's Day
            (1, 19),   // Martin Luther King Jr. Day
            (2, 16),   // Washington's Birthday
            (4, 3),    // Good Friday
            (5, 25),   // Memorial Day
            (6, 19),   // Juneteenth
            (7, 3),    // Independence Day observed (July 4 is a Saturday)
            (9, 7),    // Labor Day
            (11, 26),  // Thanksgiving
            (12, 25),  // Christmas Day
        ]
        for (month, day) in closures {
            #expect(try state(2026, month, day) == .closed, "\(month)/\(day) should be closed")
        }
    }

    @Test("The days around a closure still trade")
    func adjacentDaysStayOpen() throws {
        #expect(try state(2026, 7, 2) == .regular)
        #expect(try state(2026, 12, 24) == .regular)
        #expect(try state(2026, 11, 25) == .regular)
        #expect(try state(2026, 4, 6) == .regular)   // Easter Monday is not a US holiday
    }

    @Test("A Saturday New Year's Day closes the preceding December 31")
    func saturdayNewYearObserved() throws {
        // January 1, 2022 was a Saturday, so December 31, 2021 was the holiday.
        #expect(try state(2021, 12, 31) == .closed)
        #expect(try state(2021, 12, 30) == .regular)
    }

    @Test("A Sunday holiday closes the following Monday")
    func sundayHolidayObserved() throws {
        // January 1, 2023 was a Sunday, so January 2 was observed.
        #expect(try state(2023, 1, 2) == .closed)
        #expect(try state(2023, 1, 3) == .regular)
    }

    @Test("The overnight session belongs to the holiday it precedes")
    func overnightBeforeHoliday() throws {
        // Sunday evening before Martin Luther King Jr. Day.
        #expect(TradingCalendar.state(of: .us, at: try newYork(2026, 1, 18, 20)) == .closed)
        // Wednesday evening before Thanksgiving.
        #expect(TradingCalendar.state(of: .us, at: try newYork(2026, 11, 25, 20)) == .closed)
        // Thursday evening before Good Friday.
        #expect(TradingCalendar.state(of: .us, at: try newYork(2026, 4, 2, 20)) == .closed)
    }

    @Test("The overnight session after a holiday still trades")
    func overnightAfterHoliday() throws {
        #expect(TradingCalendar.state(of: .us, at: try newYork(2026, 1, 19, 20)) == .overnight)
        #expect(TradingCalendar.state(of: .us, at: try newYork(2026, 11, 26, 20)) == .overnight)
        #expect(TradingCalendar.state(of: .us, at: try newYork(2026, 4, 6, 20)) == .overnight)
    }

    @Test("A holiday's small hours are closed, not overnight")
    func holidaySmallHours() throws {
        #expect(TradingCalendar.state(of: .us, at: try newYork(2026, 11, 26, 2)) == .closed)
        #expect(TradingCalendar.state(of: .us, at: try newYork(2026, 4, 3, 2)) == .closed)
    }

    @Test("Refreshing stops on a holiday")
    func refreshWindow() throws {
        #expect(!TradingCalendar.isActive(.us, at: try newYork(2026, 11, 26, 10)))
        #expect(TradingCalendar.isActive(.us, at: try newYork(2026, 11, 25, 10)))
    }

    @Test("Other markets keep the weekday rule")
    func otherMarketsUnaffected() throws {
        // Thanksgiving is a US holiday only; Tokyo still trades that Thursday.
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = Market.jp.timeZone
        let tokyo = try #require(calendar.date(from: DateComponents(
            year: 2026, month: 11, day: 26, hour: 10
        )))
        #expect(TradingCalendar.state(of: .jp, at: tokyo) == .regular)
    }
}
