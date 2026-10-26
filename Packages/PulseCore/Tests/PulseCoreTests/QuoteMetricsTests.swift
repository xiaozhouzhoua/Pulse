import Testing
@testable import PulseCore

@Suite("Derived quote metrics")
struct QuoteMetricsTests {
    @Test("Amplitude uses high-low range relative to previous close")
    func amplitude() throws {
        let quote = Quote(
            symbol: SymbolID(market: .us, code: "TEST"),
            price: 102,
            previousClose: 100,
            high: 105,
            low: 95
        )

        let amplitude = try #require(quote.amplitudePercent)
        #expect(abs(amplitude - 10) < 0.000_001)
    }

    @Test("Amplitude is unavailable without a valid daily range")
    func unavailableAmplitude() {
        let missingHigh = Quote(
            symbol: SymbolID(market: .us, code: "TEST"),
            price: 102,
            previousClose: 100,
            low: 95
        )
        let zeroPreviousClose = Quote(
            symbol: SymbolID(market: .us, code: "TEST"),
            price: 102,
            previousClose: 0,
            high: 105,
            low: 95
        )
        let invalidRange = Quote(
            symbol: SymbolID(market: .us, code: "TEST"),
            price: 102,
            previousClose: 100,
            high: 95,
            low: 105
        )

        #expect(missingHigh.amplitudePercent == nil)
        #expect(zeroPreviousClose.amplitudePercent == nil)
        #expect(invalidRange.amplitudePercent == nil)
    }

    /// After the close a post-market quote moves against today's close (336.64), but
    /// today's session itself traded against yesterday's (340.42).
    private func extendedQuote(_ state: MarketState) -> Quote {
        Quote(
            symbol: SymbolID(market: .us, code: "AAPL"),
            price: 336.08,
            previousClose: 336.64,
            high: 338.61,
            low: 330.70,
            marketState: state,
            regularSession: .init(price: 336.64, previousClose: 340.42)
        )
    }

    @Test("Post-market and overnight reference the session's own previous close")
    func extendedSessionReference() throws {
        for state in [MarketState.postMarket, .overnight] {
            let quote = extendedQuote(state)
            #expect(quote.sessionReferenceClose == 340.42)
            #expect(quote.intradayReferenceClose(includesExtendedHours: true) == 340.42)
            #expect(abs(quote.intradaySessionChange(includesExtendedHours: true) - (-3.78)) < 0.000_001)
            let amplitude = try #require(quote.amplitudePercent)
            #expect(abs(amplitude - (338.61 - 330.70) / 340.42 * 100) < 0.000_001)
        }
    }

    @Test("Pre-market opens a new day only on charts that draw extended hours")
    func preMarketReference() {
        let quote = Quote(
            symbol: SymbolID(market: .us, code: "AAPL"),
            price: 337.50,
            previousClose: 336.64,
            marketState: .preMarket,
            regularSession: .init(price: 336.64, previousClose: 340.42)
        )
        #expect(quote.sessionReferenceClose == 336.64)
        #expect(quote.intradayReferenceClose(includesExtendedHours: true) == 336.64)
        #expect(abs(quote.intradaySessionChange(includesExtendedHours: true) - 0.86) < 0.000_001)
        // Without the pre-market wing the chart is still yesterday's session.
        #expect(quote.intradayReferenceClose(includesExtendedHours: false) == 340.42)
        #expect(abs(quote.intradaySessionChange(includesExtendedHours: false) - (-3.78)) < 0.000_001)
    }

    @Test("Regular and closed quotes keep their own previous close")
    func regularReference() {
        for state in [MarketState.regular, .closed] {
            let quote = Quote(
                symbol: SymbolID(market: .hk, code: "700"),
                price: 424.80,
                previousClose: 411.40,
                marketState: state
            )
            #expect(quote.sessionReferenceClose == 411.40)
            #expect(quote.intradayReferenceClose(includesExtendedHours: false) == 411.40)
            #expect(abs(quote.intradaySessionChange(includesExtendedHours: false) - 13.40) < 0.000_001)
        }
        let missingReference = Quote(
            symbol: SymbolID(market: .us, code: "AAPL"),
            price: 336.08,
            previousClose: 336.64,
            marketState: .postMarket,
            regularSession: .init(price: 336.64, previousClose: nil)
        )
        #expect(missingReference.sessionReferenceClose == 336.64)
    }
}
