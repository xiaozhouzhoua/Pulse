import Foundation

public enum SessionState: String, Sendable {
    case closed, preMarket, regular, lunchBreak, postMarket
    /// US overnight session (Sun 20:00 ET through Fri 04:00 ET, in nightly slices)
    case overnight
}

/// Trading sessions per market (in each exchange's time zone).
/// Full-day US exchange holidays are modeled (NYSE/Nasdaq schedule). The Asian
/// exchanges still use the Monday–Friday rule: their lunar holidays need a
/// published calendar per year, and a wrong "closed" would hide a live session.
/// Japan makes the remaining gap the most visible: about twenty public holidays
/// plus the 12/31–1/3 exchange closure means roughly six weeks of weekdays a
/// year are reported open when Tokyo is shut.
public enum TradingCalendar {
    public static func state(of market: Market, at date: Date = .now) -> SessionState {
        if market == .crypto { return .regular }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = market.timeZone
        let comps = calendar.dateComponents([.weekday, .hour, .minute], from: date)
        guard let weekday = comps.weekday, let hour = comps.hour, let minute = comps.minute else {
            return .closed
        }
        let m = hour * 60 + minute

        // Metals run almost continuously: Sun 18:00 ET through Fri 17:00 ET, pausing
        // one hour a day for settlement. Like the US overnight session, that reaches
        // outside the Monday–Friday rule below.
        if market == .metal {
            if weekday == 1 { return m >= 18 * 60 ? .regular : .closed }  // Sunday evening opens the week
            guard (2...6).contains(weekday) else { return .closed }       // Saturday has no session
            if m < 17 * 60 { return .regular }
            if weekday == 6 { return .closed }                            // Friday 17:00 closes the week
            return m >= 18 * 60 ? .regular : .closed                      // 17:00–18:00 settlement break
        }

        // Shanghai metals trade a night leg ahead of the day session, so like the
        // US overnight it reaches outside the Monday–Friday rule below. The two
        // exchanges differ slightly — the Gold Exchange opens at 20:00 and settles
        // at 15:30, the Futures Exchange at 21:00 and 15:00 — so the window is
        // their union: an instrument simply has no bars in the part it misses.
        if market == .metalCN {
            if m >= 20 * 60 { return (2...6).contains(weekday) ? .regular : .closed }
            // The small hours belong to the previous evening's session: Saturday
            // has one because Friday night ran into it, Monday does not.
            if m < 2 * 60 + 30 { return (3...7).contains(weekday) ? .regular : .closed }
            guard (2...6).contains(weekday) else { return .closed }
            if (9 * 60)..<(11 * 60 + 30) ~= m { return .regular }
            if (11 * 60 + 30)..<(13 * 60 + 30) ~= m { return .lunchBreak }
            if (13 * 60 + 30)..<(15 * 60 + 30) ~= m { return .regular }
            return .closed
        }

        // The US overnight session runs Sun 20:00 ET through Fri 04:00 ET, so it is the one
        // stretch that exists outside the Monday–Friday rule below. A holiday closes
        // the overnight session that belongs to it, including the evening before.
        if market == .us {
            if let sessionDay = usOvernightSessionDay(at: date) {
                return isUSHoliday(sessionDay) ? .closed : .overnight
            }
            if isUSHoliday(CalendarDay(date, in: market.timeZone)) { return .closed }
        }
        guard (2...6).contains(weekday) else { return .closed }

        switch market {
        case .sh, .sz:
            if (9 * 60 + 15)..<(11 * 60 + 30) ~= m { return .regular }  // Includes the opening call auction
            if (11 * 60 + 30)..<(13 * 60) ~= m { return .lunchBreak }
            if (13 * 60)..<(15 * 60) ~= m { return .regular }
            return .closed
        case .hk:
            if (9 * 60 + 30)..<(12 * 60) ~= m { return .regular }
            if (12 * 60)..<(13 * 60) ~= m { return .lunchBreak }
            if (13 * 60)..<(16 * 60 + 10) ~= m { return .regular }  // Includes the closing auction
            return .closed
        case .us:
            if (4 * 60)..<(9 * 60 + 30) ~= m { return .preMarket }
            if (9 * 60 + 30)..<(16 * 60) ~= m { return .regular }
            if (16 * 60)..<(20 * 60) ~= m { return .postMarket }
            return .closed
        case .jp:
            // Tokyo moved its close from 15:00 to 15:30 in November 2024; the
            // 11:30–12:30 lunch break has not changed.
            if (9 * 60)..<(11 * 60 + 30) ~= m { return .regular }
            if (11 * 60 + 30)..<(12 * 60 + 30) ~= m { return .lunchBreak }
            if (12 * 60 + 30)..<(15 * 60 + 30) ~= m { return .regular }
            return .closed
        case .kr, .kq:
            // Seoul runs one continuous session, closing auction included. Its
            // call auctions on either side are not modeled: no wired source
            // publishes them, so claiming the state would outrun the data.
            if (9 * 60)..<(15 * 60 + 30) ~= m { return .regular }
            return .closed
        case .crypto, .metal:
            return .regular
        case .metalCN:
            return .closed  // Handled above; every SHFE branch returns already.
        }
    }

    /// Whether this market is currently worth refreshing at high frequency.
    /// Overnight counts as inactive here: most sources have nothing new then, and the ones
    /// that do (Longbridge) declare it via `ProviderDescriptor.overnightMarkets`.
    public static func isActive(_ market: Market, at date: Date = .now) -> Bool {
        switch state(of: market, at: date) {
        case .regular, .preMarket, .postMarket: true
        case .closed, .lunchBreak, .overnight: false
        }
    }

    public static func anyActive(_ markets: some Sequence<Market>, at date: Date = .now) -> Bool {
        markets.contains { isActive($0, at: date) }
    }

    /// The trading day a moment belongs to, read in the market's own time zone.
    /// The US overnight session runs from 20:00 ET into the small hours, so it
    /// belongs to the session that follows it rather than the date it starts on.
    /// Metals keep their exchange calendar day: that is how both of their sources
    /// report them, whatever hour of the continuous session a bar falls in.
    public static func tradingDay(of market: Market, at date: Date) -> CalendarDay {
        let day = CalendarDay(date, in: market.timeZone)
        guard market == .us, let sessionDay = usOvernightSessionDay(at: date) else { return day }
        return sessionDay
    }

    // MARK: - US exchange holidays

    /// The overnight session's trading day, or nil when the moment is not in
    /// an overnight slice. Kept separate from `state` so `tradingDay` can ask
    /// without recursing through the holiday check.
    private static func usOvernightSessionDay(at date: Date) -> CalendarDay? {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = Market.us.timeZone
        let comps = calendar.dateComponents([.weekday, .hour], from: date)
        guard let weekday = comps.weekday, let hour = comps.hour else { return nil }
        let day = CalendarDay(date, in: Market.us.timeZone)
        if weekday == 1 { return hour >= 20 ? adding(days: 1, to: day) : nil } // Sunday evening opens Monday
        if (2...6).contains(weekday), hour < 4 { return day }                   // Mon–Fri small hours
        if (2...5).contains(weekday), hour >= 20 { return adding(days: 1, to: day) } // Mon–Thu nights
        return nil
    }

    /// Full-day closures only. Early closes (1:00 p.m. ET) are not modeled:
    /// the extra hours still carry post-market prints, and a wrong "closed"
    /// costs more than a few extra polls.
    private static func isUSHoliday(_ day: CalendarDay) -> Bool {
        // A Saturday New Year's Day is observed on December 31 of the previous
        // year, so a date also has to be checked against the next year's set.
        usHolidays(in: day.year).contains(day) || usHolidays(in: day.year + 1).contains(day)
    }

    /// Holiday sets are recomputed once per year rather than once per symbol per
    /// tick: the scheduler asks this question for every quote it refreshes.
    private static let holidayCacheLock = NSLock()
    nonisolated(unsafe) private static var holidayCache: [Int: Set<CalendarDay>] = [:]

    private static func usHolidays(in year: Int) -> Set<CalendarDay> {
        holidayCacheLock.lock()
        defer { holidayCacheLock.unlock() }
        if let cached = holidayCache[year] { return cached }
        let holidays: Set<CalendarDay> = [
            observed(month: 1, day: 1, in: year),              // New Year's Day
            nthWeekday(3, weekday: 2, month: 1, year: year),   // Martin Luther King Jr. Day
            nthWeekday(3, weekday: 2, month: 2, year: year),   // Washington's Birthday
            goodFriday(in: year),
            lastWeekday(2, month: 5, year: year),              // Memorial Day
            observed(month: 6, day: 19, in: year),             // Juneteenth
            observed(month: 7, day: 4, in: year),              // Independence Day
            nthWeekday(1, weekday: 2, month: 9, year: year),   // Labor Day
            nthWeekday(4, weekday: 5, month: 11, year: year),  // Thanksgiving
            observed(month: 12, day: 25, in: year),            // Christmas Day
        ]
        holidayCache[year] = holidays
        return holidays
    }

    /// Saturday closures move to the preceding Friday, Sunday ones to Monday.
    private static func observed(month: Int, day: Int, in year: Int) -> CalendarDay {
        let base = CalendarDay(year: year, month: month, day: day)
        switch weekday(of: base) {
        case 7: return adding(days: -1, to: base)
        case 1: return adding(days: 1, to: base)
        default: return base
        }
    }

    private static func nthWeekday(_ nth: Int, weekday: Int, month: Int, year: Int) -> CalendarDay {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = Market.us.timeZone
        guard let first = calendar.date(from: DateComponents(year: year, month: month, day: 1)) else {
            return CalendarDay(year: year, month: month, day: 1)
        }
        let offset = (weekday - calendar.component(.weekday, from: first) + 7) % 7
        return CalendarDay(year: year, month: month, day: 1 + offset + (nth - 1) * 7)
    }

    private static func lastWeekday(_ weekday: Int, month: Int, year: Int) -> CalendarDay {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = Market.us.timeZone
        let nextMonth = month == 12 ? 1 : month + 1
        let nextYear = month == 12 ? year + 1 : year
        guard let firstOfNext = calendar.date(from: DateComponents(year: nextYear, month: nextMonth, day: 1)),
              let last = calendar.date(byAdding: .day, value: -1, to: firstOfNext) else {
            return CalendarDay(year: year, month: month, day: 1)
        }
        let offset = (calendar.component(.weekday, from: last) - weekday + 7) % 7
        return CalendarDay(
            year: year,
            month: month,
            day: calendar.component(.day, from: last) - offset
        )
    }

    private static func goodFriday(in year: Int) -> CalendarDay {
        adding(days: -2, to: easterSunday(in: year))
    }

    /// Anonymous Gregorian algorithm for Easter Sunday.
    private static func easterSunday(in year: Int) -> CalendarDay {
        let a = year % 19
        let b = year / 100
        let c = year % 100
        let d = b / 4
        let e = b % 4
        let f = (b + 8) / 25
        let g = (b - f + 1) / 3
        let h = (19 * a + b - d - g + 15) % 30
        let i = c / 4
        let k = c % 4
        let l = (32 + 2 * e + 2 * i - h - k) % 7
        let m = (a + 11 * h + 22 * l) / 451
        let month = (h + l - 7 * m + 114) / 31
        let day = ((h + l - 7 * m + 114) % 31) + 1
        return CalendarDay(year: year, month: month, day: day)
    }

    private static func weekday(of day: CalendarDay) -> Int {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = Market.us.timeZone
        guard let date = calendar.date(from: DateComponents(year: day.year, month: day.month, day: day.day)) else {
            return 0
        }
        return calendar.component(.weekday, from: date)
    }

    private static func adding(days: Int, to day: CalendarDay) -> CalendarDay {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = Market.us.timeZone
        guard let date = calendar.date(from: DateComponents(year: day.year, month: day.month, day: day.day)),
              let shifted = calendar.date(byAdding: .day, value: days, to: date) else {
            return day
        }
        return CalendarDay(shifted, in: Market.us.timeZone)
    }
}

/// A calendar day identity: which day something happened on, not when. Days
/// read in different time zones (a trade date entered locally, a session date
/// read in the exchange's zone) compare directly instead of being turned back
/// into instants that would answer a different question.
public struct CalendarDay: Comparable, Hashable, Sendable {
    public var year: Int
    public var month: Int
    public var day: Int

    public init(year: Int, month: Int, day: Int) {
        self.year = year
        self.month = month
        self.day = day
    }

    public init(_ date: Date, in timeZone: TimeZone) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        self.init(
            year: components.year ?? 0,
            month: components.month ?? 0,
            day: components.day ?? 0
        )
    }

    public static func < (lhs: CalendarDay, rhs: CalendarDay) -> Bool {
        (lhs.year, lhs.month, lhs.day) < (rhs.year, rhs.month, rhs.day)
    }
}
