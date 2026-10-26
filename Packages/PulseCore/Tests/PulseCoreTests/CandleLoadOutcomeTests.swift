import Foundation
import Testing
@testable import PulseCore

/// The detail chart's honesty rule: a failed load must be distinguishable from
/// a source that genuinely has no data for the period.
@MainActor
@Suite("Candle load outcome")
struct CandleLoadOutcomeTests {
    private func makeEngine(_ provider: MockProvider, defaults: UserDefaults) -> RefreshEngine {
        RefreshEngine(
            provider: CompositeProvider(providers: [provider]),
            store: MarketStore(),
            watchlist: WatchlistStore(defaults: defaults, defaultGroupName: "Watchlist")
        )
    }

    @Test("A failed load with no cache reports failed and stays empty")
    func failureWithoutCache() async throws {
        let suiteName = "CandleLoadOutcomeTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let provider = MockProvider(id: "p", candleError: ProviderError.network(underlying: "offline"))
        let engine = makeEngine(provider, defaults: defaults)
        let outcome = await engine.loadCandles(
            for: SymbolID(market: .us, code: "AAPL"), period: .day, count: 10
        )
        #expect(outcome.failed)
        #expect(outcome.candles.isEmpty)
    }

    @Test("A failed load still serves whatever stale cache exists")
    func failureWithStaleCache() async throws {
        let suiteName = "CandleLoadOutcomeTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let symbol = SymbolID(market: .us, code: "AAPL")
        let market = MarketStore()
        let stale = [Candle(time: .now.addingTimeInterval(-3_600), open: 1, high: 2, low: 0.5, close: 1.5)]
        // Older than the 600s freshness a daily load accepts, so the load has to
        // go to the network and exercise the failure fallback.
        market.cache(
            candles: stale,
            for: CandleCacheKey(symbol: symbol, period: .day),
            fetchedAt: .now.addingTimeInterval(-700)
        )

        let provider = MockProvider(id: "p", candleError: ProviderError.network(underlying: "offline"))
        let engine = RefreshEngine(
            provider: CompositeProvider(providers: [provider]),
            store: market,
            watchlist: WatchlistStore(defaults: defaults, defaultGroupName: "Watchlist")
        )
        let outcome = await engine.loadCandles(for: symbol, period: .day, count: 10)
        #expect(outcome.failed)
        #expect(outcome.candles == stale)
    }

    @Test("A successful load is not marked failed")
    func success() async throws {
        let suiteName = "CandleLoadOutcomeTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let provider = MockProvider(id: "p")
        let engine = makeEngine(provider, defaults: defaults)
        let outcome = await engine.loadCandles(
            for: SymbolID(market: .us, code: "AAPL"), period: .day, count: 10
        )
        #expect(!outcome.failed)
        #expect(!outcome.candles.isEmpty)
    }

    @Test("A fresh cache hit is served without asking and without failure")
    func freshCacheHit() async throws {
        let suiteName = "CandleLoadOutcomeTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let symbol = SymbolID(market: .us, code: "AAPL")
        let market = MarketStore()
        let fresh = [Candle(time: .now, open: 1, high: 2, low: 0.5, close: 1.5)]
        market.cache(candles: fresh, for: CandleCacheKey(symbol: symbol, period: .day))

        let provider = MockProvider(id: "p", candleError: ProviderError.network(underlying: "offline"))
        let engine = RefreshEngine(
            provider: CompositeProvider(providers: [provider]),
            store: market,
            watchlist: WatchlistStore(defaults: defaults, defaultGroupName: "Watchlist")
        )
        let outcome = await engine.loadCandles(for: symbol, period: .day, count: 10)
        #expect(!outcome.failed)
        #expect(outcome.candles == fresh)
    }
}
