import Foundation
import Testing
@testable import PulseCore

/// Staleness turns on the market the quote belongs to and the latency its
/// source promises, so each rule gets its own anchored moment.
@Suite("Quote staleness")
struct QuoteStalenessTests {
    /// 2026-08-19 is a Wednesday: every securities market trades a regular day.
    private func at(_ hour: Int, _ minute: Int = 0, market: Market) throws -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = market.timeZone
        return try #require(calendar.date(
            from: DateComponents(year: 2026, month: 8, day: 19, hour: hour, minute: minute)
        ))
    }

    private func quote(
        _ market: Market,
        code: String = "TEST",
        timestamp: Date,
        state: MarketState? = nil
    ) -> Quote {
        Quote(
            symbol: SymbolID(market: market, code: code),
            price: 100,
            previousClose: 99,
            timestamp: timestamp,
            marketState: state
        )
    }

    @Test("A realtime source within its cadence is current")
    func freshRealtime() throws {
        let now = try at(12, market: .us)
        let age = QuoteStaleness.age(
            for: quote(.us, timestamp: now.addingTimeInterval(-60)),
            now: now,
            sourceDelay: 0,
            pollCadence: 15
        )
        #expect(age == nil)
    }

    @Test("Beyond delay plus cadence the age is reported")
    func stalledRealtime() throws {
        let now = try at(12, market: .us)
        let age = QuoteStaleness.age(
            for: quote(.us, timestamp: now.addingTimeInterval(-300)),
            now: now,
            sourceDelay: 0,
            pollCadence: 15
        )
        #expect(age != nil)
        #expect(abs(age! - 300) < 0.001)
    }

    @Test("A delayed source owes nothing until its own delay is exceeded")
    func delayedSourceAllowance() throws {
        let now = try at(12, market: .us)
        let stalled = QuoteStaleness.age(
            for: quote(.us, timestamp: now.addingTimeInterval(-900)),
            now: now,
            sourceDelay: 15 * 60,
            pollCadence: 15
        )
        #expect(stalled == nil)

        let beyond = QuoteStaleness.age(
            for: quote(.us, timestamp: now.addingTimeInterval(-1_200)),
            now: now,
            sourceDelay: 15 * 60,
            pollCadence: 15
        )
        #expect(beyond != nil)
    }

    @Test("A quiet instrument gets a two-minute floor whatever the cadence")
    func minimumAllowance() throws {
        let now = try at(12, market: .us)
        // Delay 0 + a 1-second poll cadence would allow 61s; the floor keeps
        // a 90s-old print from already reading as broken.
        let withinFloor = QuoteStaleness.age(
            for: quote(.us, timestamp: now.addingTimeInterval(-90)),
            now: now,
            sourceDelay: 0,
            pollCadence: 1
        )
        #expect(withinFloor == nil)

        let pastFloor = QuoteStaleness.age(
            for: quote(.us, timestamp: now.addingTimeInterval(-150)),
            now: now,
            sourceDelay: 0,
            pollCadence: 1
        )
        #expect(pastFloor != nil)
    }

    @Test("Closed and lunch sessions owe no updates however old the print")
    func quietSessions() throws {
        // 21:00 ET Wednesday: post-market over, closed for the night.
        let evening = try at(21, market: .us)
        #expect(QuoteStaleness.age(
            for: quote(.us, timestamp: evening.addingTimeInterval(-3 * 3600)),
            now: evening,
            sourceDelay: 0,
            pollCadence: 15
        ) == nil)

        // 12:15 in Shanghai: lunch break.
        let lunch = try at(12, 15, market: .sh)
        #expect(QuoteStaleness.age(
            for: quote(.sh, timestamp: lunch.addingTimeInterval(-3 * 3600)),
            now: lunch,
            sourceDelay: 0,
            pollCadence: 15
        ) == nil)

        // Saturday in Hong Kong.
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = Market.hk.timeZone
        let saturday = try #require(calendar.date(
            from: DateComponents(year: 2026, month: 8, day: 22, hour: 12)
        ))
        #expect(QuoteStaleness.age(
            for: quote(.hk, timestamp: saturday.addingTimeInterval(-24 * 3600)),
            now: saturday,
            sourceDelay: 0,
            pollCadence: 15
        ) == nil)
    }

    @Test("Overnight counts only when the quote itself trades the session")
    func overnightSession() throws {
        // Wednesday 22:00 ET is the overnight session.
        let overnight = try at(22, market: .us)
        let stale = quote(.us, timestamp: overnight.addingTimeInterval(-600), state: .overnight)
        let regularPrint = quote(.us, timestamp: overnight.addingTimeInterval(-600))
        #expect(QuoteStaleness.age(
            for: stale, now: overnight, sourceDelay: 0, pollCadence: 15
        ) != nil)
        #expect(QuoteStaleness.age(
            for: regularPrint, now: overnight, sourceDelay: 0, pollCadence: 15
        ) == nil)
    }

    @Test("Crypto trades around the clock and can stall any minute")
    func cryptoAlwaysTrades() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = Market.crypto.timeZone
        // Early Sunday: nothing else trades, crypto does.
        let sunday = try #require(calendar.date(
            from: DateComponents(year: 2026, month: 8, day: 23, hour: 3)
        ))
        #expect(QuoteStaleness.age(
            for: quote(.crypto, code: "BTCUSDT", timestamp: sunday.addingTimeInterval(-300)),
            now: sunday,
            sourceDelay: 0,
            pollCadence: 15
        ) != nil)
        #expect(QuoteStaleness.age(
            for: quote(.crypto, code: "BTCUSDT", timestamp: sunday.addingTimeInterval(-30)),
            now: sunday,
            sourceDelay: 0,
            pollCadence: 15
        ) == nil)
    }

    @Test("Extended sessions allow a quiet quarter-hour but not a silent one")
    func extendedSessionsOweUpdates() throws {
        let preMarket = try at(8, market: .us)
        let postMarket = try at(17, market: .us)
        for now in [preMarket, postMarket] {
            // Pre/post prints are sparse: five quiet minutes are ordinary.
            #expect(QuoteStaleness.age(
                for: quote(.us, timestamp: now.addingTimeInterval(-300)),
                now: now,
                sourceDelay: 0,
                pollCadence: 15
            ) == nil)
            // Twenty minutes without a print means the feed went quiet.
            #expect(QuoteStaleness.age(
                for: quote(.us, timestamp: now.addingTimeInterval(-1_200)),
                now: now,
                sourceDelay: 0,
                pollCadence: 15
            ) != nil)
        }
    }

    @Test("A prior-day print on a calendar holiday is a calendar gap, not a stall")
    func holidayBlindspot() throws {
        // Wednesday 12:00 ET with the newest print from Tuesday's close: the
        // calendar does not know holidays, so the session reads as live while
        // the exchange is dark. No single session spans eight hours, so a gap
        // past that is the calendar's blind spot.
        let holiday = try at(12, market: .us)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = Market.us.timeZone
        let tuesdayClose = try #require(calendar.date(
            from: DateComponents(year: 2026, month: 8, day: 18, hour: 16)
        ))
        #expect(holiday.timeIntervalSince(tuesdayClose) > 8 * 3600)
        #expect(QuoteStaleness.age(
            for: quote(.us, timestamp: tuesdayClose),
            now: holiday,
            sourceDelay: 0,
            pollCadence: 15
        ) == nil)
        // Crypto has no calendar gaps: a multi-hour silence stays reportable.
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = Market.crypto.timeZone
        let sundayCrypto = try #require(utc.date(
            from: DateComponents(year: 2026, month: 8, day: 23, hour: 3)
        ))
        #expect(QuoteStaleness.age(
            for: quote(.crypto, code: "BTCUSDT", timestamp: sundayCrypto.addingTimeInterval(-10 * 3600)),
            now: sundayCrypto,
            sourceDelay: 0,
            pollCadence: 15
        ) != nil)
    }

    @Test("A session that just opened gets time for its first poll")
    func openingGrace() throws {
        // 13:02 in Shanghai: lunch ended at 13:00 and the scheduler is still on
        // its off-hours cadence, so the morning's 11:29 print is not yet a stall.
        let justReopened = try at(13, 2, market: .sh)
        let morningPrint = try at(11, 29, market: .sh)
        #expect(QuoteStaleness.age(
            for: quote(.sh, timestamp: morningPrint),
            now: justReopened,
            sourceDelay: 0,
            pollCadence: 15
        ) == nil)

        // Three minutes in, the session has had its polls.
        let settled = try at(13, 5, market: .sh)
        #expect(QuoteStaleness.age(
            for: quote(.sh, timestamp: morningPrint),
            now: settled,
            sourceDelay: 0,
            pollCadence: 15
        ) != nil)
    }
}
