import Foundation

/// Whether a quote has stopped updating while its market should still be
/// printing prices — the difference between a live number that merely steps
/// and one whose source has gone quiet.
///
/// The exchange timestamp is the basis: providers stamp a quote with the
/// market time of the last print, so a wall clock running far past it during
/// an active session means the price on screen is older than its source
/// promises. Sessions where updates legitimately pause (closed, lunch,
/// overnight without a source quoting it) never count, and each source's own
/// delay plus poll cadence is its allowance.
public enum QuoteStaleness {
    /// How long ago the quote's last print happened when that is longer than
    /// its source and session can explain, in seconds; nil while the quote is
    /// current or its market owes no updates.
    ///
    /// - Parameters:
    ///   - quote: The quote on screen. Its timestamp is exchange time.
    ///   - now: Wall clock; injectable for tests.
    ///   - sourceDelay: The delay the quote's source declares for its market.
    ///   - pollCadence: How often the app asks that source for quotes.
    public static func age(
        for quote: Quote,
        now: Date = .now,
        sourceDelay: TimeInterval,
        pollCadence: TimeInterval
    ) -> TimeInterval? {
        let market = quote.symbol.market
        let state = TradingCalendar.state(of: market, at: now)
        switch state {
        case .regular, .preMarket, .postMarket:
            break
        case .overnight:
            // Most sources have nothing to say overnight; only a quote already
            // stamped overnight (its source trades the session) owes updates.
            guard quote.marketState == .overnight else { return nil }
        case .closed, .lunchBreak:
            return nil
        }

        if inOpeningGrace(market, at: now) { return nil }

        let age = now.timeIntervalSince(quote.timestamp)
        // The calendar knows session times but not exchange holidays: on a holiday
        // the state machine still reports a live session while the newest print is
        // from the prior trading day. A gap no single session could span is a
        // calendar gap, not a source that went quiet mid-session. Crypto trades
        // around the clock, so for it a long gap is always real.
        if market != .crypto, age > maxPlausibleStall { return nil }

        // Delayed data trails by its delay and polled data steps at its cadence;
        // a further minute absorbs scheduling jitter. A two-minute floor keeps
        // a quiet instrument from reading as broken before it can matter.
        // Equity extended sessions relax that floor: pre/post prints are sparse,
        // so a quiet quarter-hour there is ordinary trading, not a broken feed.
        let floor: TimeInterval = (state == .preMarket || state == .postMarket) ? 900 : 120
        let allowance = max(sourceDelay + pollCadence + 60, floor)
        return age > allowance ? age : nil
    }

    /// Longer than any single session on any covered exchange (metals' connected
    /// legs included); see the holiday note in `age(for:...)`.
    private static let maxPlausibleStall: TimeInterval = 8 * 3600

    /// A session that just opened owes its first print yet: the scheduler leaves
    /// its slow off-hours cadence within a tick or two of the boundary, and the
    /// previous session's last print would read as stalled for exactly that gap.
    private static func inOpeningGrace(_ market: Market, at now: Date) -> Bool {
        TradingCalendar.isActive(market, at: now)
            && !TradingCalendar.isActive(market, at: now.addingTimeInterval(-150))
    }
}
