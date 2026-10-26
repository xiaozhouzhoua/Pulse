import SwiftUI
import PulseCore
import PulseUI

struct DetailView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.pulseHost) private var host
    let symbol: SymbolID
    @Binding var route: PopoverRoute

    @State private var period: CandlePeriod = .minute1
    @State private var candles: [Candle] = []
    /// What `candles` hold, and by the same token which request they answer for.
    /// A switch leaves the previous period's bars in place for a moment; they
    /// must neither be drawn under the new period's axis nor counted as its
    /// answer. Only once this matches the request on screen does an empty
    /// `candles` mean the source had nothing.
    @State private var candlesKey: CandleCacheKey?
    /// The drawable subset of `sourceCandles` for the session setting on screen.
    /// Minute-K loads keep every US session, so filtering here — once per data
    /// change rather than on every body evaluation as quote ticks arrive —
    /// keeps a whole-series filter pass out of the render path.
    @State private var onScreenCandles: [Candle] = []
    @State private var isLoading = false
    /// The load for the request on screen failed and left nothing to show: the
    /// empty chart is a transport answer, not the source's, so it says so and
    /// offers a retry instead of claiming the period has no data.
    @State private var chartLoadFailed = false
    /// Retrying re-runs the load task; the nonce makes the changed request id.
    @State private var chartRetryNonce = 0
    @State private var isFirstLoad = true
    @State private var shareFeedback: ShareFeedback?
    /// Owned here (not in the chart) so sharing can read the zoomed candle window.
    @State private var candleViewport = CandleChartViewport()

    private static let minutePeriods: [CandlePeriod] = [
        .minute5, .minute15, .minute30, .hour1,
    ]

    private var density: DetailDensity { DetailDensity(host: host) }

    var body: some View {
        layout
        .toolbar {
            if host == .pinnedWindow {
                FlexibleToolbarSpacer()
            }
            // Windowed hosts carry page actions in the title bar; the panel has
            // none and keeps them in its header row.
            if host != .menuBar {
                ToolbarItemGroup(placement: .primaryAction) {
                    toolbarActions
                }
            }
        }
        .onAppear {
            // A wide plot spreads the panel's 60 bars into slabs; twice the
            // history keeps candles at about the width they have in the panel.
            candleViewport.setPreferredVisibleCount(host == .desktop ? 120 : 60)
            maybeOfferKlineTourStep()
        }
        // The desktop window keeps one page alive across selections; a zoomed
        // window into the previous symbol's history means nothing for the next.
        .onChange(of: symbol) { _, _ in candleViewport.reset() }
        .onDisappear {
            // Leaving with the candle bubble up counts as the step seen; the pin
            // stop then presents back on the list. An offer that never fired
            // stays pending for the next detail visit.
            if appState.onboarding.activeTourStep == .kline {
                appState.onboarding.completeStep(.kline)
            }
        }
        // Any period switch is the lesson learned, daily or not.
        .onChange(of: period) { _, _ in
            appState.onboarding.completeStep(.kline)
        }
        // Reapply the session filter when the loaded series, the request on
        // screen, or the extended-hours setting changes — not on every tick.
        .onChange(of: chartCandleStamp, initial: true) { _, _ in
            rebuildOnScreenCandles()
        }
        // Real-time push while the page is on screen: each tick lands in the store, and the
        // price / market-time views animate through their existing transitions. Closing the
        // page cancels the task, which unsubscribes upstream; polling remains the fallback.
        .task(id: symbol) {
            guard let stream = appState.provider.quoteStream(for: [symbol]) else { return }
            do {
                for try await quote in stream {
                    appState.ingestStreamedQuote(quote)
                }
            } catch {
                // Stream dropped (e.g. socket reconnect) — the 15s polling loop still updates the page.
            }
        }
        // Symbols opened from search aren't in the watchlist, so the engine's polling
        // loop never covers them; the page runs its own light poll until it closes
        // (or the symbol gets added, at which point the engine takes over).
        .task(id: symbol) {
            while !Task.isCancelled {
                if appState.watchlist.item(for: symbol) == nil {
                    if let quote = try? await appState.provider.quotes(for: [symbol]).first {
                        appState.ingestStreamedQuote(quote)
                    }
                }
                try? await Task.sleep(for: .seconds(15))
            }
        }
        .task(id: ChartRequestID(key: chartRequest, retry: chartRetryNonce)) {
            let request = chartRequest
            let taskStart = ContinuousClock.now
            chartLoadFailed = false
            // Switching periods repaints from whatever is already cached for the
            // new one, however old, and the refresh replaces it in place — the
            // chart never has to blank out to change resolution. The first load
            // skips this: its render would land mid-push (see the clearance below).
            if !isFirstLoad,
               let cached = appState.market.cachedCandles(for: request, maxAge: .infinity),
               !cached.isEmpty {
                candles = cached
                candlesKey = request
            }
            // Show the spinner only when loading is actually slow: a sub-150ms load
            // (cache hit) swaps silently instead of flashing a progress indicator.
            let spinnerDelay = Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(150))
                guard !Task.isCancelled else { return }
                isLoading = true
            }
            defer {
                spinnerDelay.cancel()
                isLoading = false
            }
            let outcome = await appState.engine.loadCandles(
                for: request.symbol, period: request.period,
                count: candleCount(for: request.period)
            )
            let loaded = outcome.candles
            if isFirstLoad {
                // The first load starts while the push transition is still running,
                // and Swift Charts' first render is expensive (up to 1440 intraday
                // points) — hold a fast (cached) result until the slide has settled.
                let clearance: Duration = .milliseconds(350)
                let elapsed = taskStart.duration(to: .now)
                if elapsed < clearance {
                    try? await Task.sleep(for: clearance - elapsed)
                }
                isFirstLoad = false
            }
            guard !Task.isCancelled else { return }
            if outcome.failed, loaded.isEmpty {
                chartLoadFailed = true
                return
            }
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.18)) {
                candles = loaded
                candlesKey = request
            }
        }
    }

    /// Symbol + period identify a chart load: the page is reused across symbols,
    /// so a reload owes itself to either changing. The nonce counts retries.
    private struct ChartRequestID: Hashable {
        var key: CandleCacheKey
        var retry: Int
    }

    /// Symbol + period identify a chart load: the page is reused across symbols,
    /// so a reload owes itself to either changing.
    private var chartRequest: CandleCacheKey {
        CandleCacheKey(symbol: symbol, period: period)
    }

    @ViewBuilder
    private var layout: some View {
        if host == .desktop {
            desktopLayout
        } else {
            panelLayout
        }
    }

    // Page flow: price hero → trend chart → market stats → position.
    // Source/time/delay metadata sits at the hero's top-right corner, annotating the price.
    private var panelLayout: some View {
        VStack(spacing: 0) {
            heroSection
            sectionSeparator
            chartSection
            sectionSeparator
            QuoteStatsView(symbol: symbol, density: density)
            positionArea
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .softScrollEdgeEffect(for: .all)
        // Navigation and instrument identity belong to the page, not the window.
        // Keeping this row inline also aligns it with the pinned watchlist's first
        // content row instead of squeezing a long name between the traffic lights
        // and the title-bar actions.
        .safeAreaInset(edge: .top, spacing: 0) { header }
    }

    /// The desktop window gives the chart the page: stats and the position live in
    /// the details column beside it, and the instrument's identity moves into the
    /// window title, where a long name no longer competes with the price.
    private var desktopLayout: some View {
        VStack(spacing: 0) {
            // A new identity per symbol: rolling the digits from one instrument's
            // price to another's would animate a change that never happened.
            heroSection
                .id(symbol)
            sectionSeparator
            chartSection
                .padding(.bottom, density.horizontalPadding)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .overlay(alignment: .topTrailing) {
            if let shareFeedback {
                ShareFeedbackHUD(feedback: shareFeedback)
                    .padding(.top, 10)
                    .padding(.trailing, density.horizontalPadding)
                    .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .trailing)))
                    .allowsHitTesting(false)
            }
        }
        .navigationTitle(appState.displayName(for: symbol))
        .navigationSubtitle("\(symbol.market.displayName) · \(symbol.displayCode)")
    }

    private var quote: Quote? { appState.market.quote(for: symbol) }
    private var item: WatchItem? { appState.watchlist.item(for: symbol) }

    private var currencyCode: String? {
        quote?.currencyCode ?? symbol.currencyCode
    }

    /// K-line periods load history behind the zoomable window (the chart shows the latest
    /// ~60 bars by default). Intraday resolutions retain enough bars to pan backward while
    /// staying inside Longbridge/Binance's 1,000-candle request ceiling.
    private func candleCount(for period: CandlePeriod) -> Int {
        switch period {
        case .minute5, .minute15, .minute30, .hour1:
            guard let minutes = period.intradayMinutes else { return 240 }
            let sessionMinutes = switch symbol.market {
            case .sh, .sz: 240
            case .hk: 330
            // Providers fetch all sessions; the presentation setting filters to
            // regular hours or 04:00–20:00 ET without a second request.
            case .us: 16 * 60
            case .crypto: 24 * 60
            case .metal: 23 * 60
            case .metalCN: 780
            case .jp: 330
            case .kr, .kq: 390
            }
            let historyDays = switch symbol.market {
            case .crypto, .metal: 1
            case .us, .hk, .sh, .sz, .metalCN, .jp, .kr, .kq: 5
            }
            return min(max(sessionMinutes / minutes * historyDays, 240), 1_000)
        case .day: return 250
        case .week: return 260
        case .month: return 240
        case .minute1:
            return IntradayTrendSnapshot.recommendedCandleCount(for: symbol.market)
        }
    }

    /// Only bars that belong to what is on screen now. Everything the chart
    /// draws goes through here, so a pending switch shows its own loading state
    /// rather than the outgoing period's data.
    private var sourceCandles: [Candle] {
        if candlesKey == chartRequest { return candles }
        // The reload task lands a frame later than the switch itself. Painting
        // the cache here rather than waiting for it closes that frame, so going
        // back to a period already loaded once never blanks at all.
        guard !isFirstLoad else { return [] }
        return appState.market.cachedCandles(for: chartRequest, maxAge: .infinity) ?? []
    }

    /// What `onScreenCandles` must be rebuilt for. Count and endpoint times
    /// stand in for full array equality — enough to catch any reload that
    /// adds or extends bars while comparing in nanoseconds per body pass.
    private struct ChartCandleStamp: Equatable {
        var loadedKey: CandleCacheKey?
        var requestKey: CandleCacheKey
        var isFirstLoad: Bool
        var count: Int
        var firstTime: TimeInterval
        var lastTime: TimeInterval
        var includesExtendedHours: Bool
    }

    private var chartCandleStamp: ChartCandleStamp {
        ChartCandleStamp(
            loadedKey: candlesKey,
            requestKey: chartRequest,
            isFirstLoad: isFirstLoad,
            count: candles.count,
            firstTime: candles.first?.time.timeIntervalSince1970 ?? 0,
            lastTime: candles.last?.time.timeIntervalSince1970 ?? 0,
            includesExtendedHours: appState.showsExtendedHours(for: symbol)
        )
    }

    /// Minute K data is fetched with all US sessions so the setting can switch
    /// instantly; this reapplies the session filter whenever the underlying
    /// data or the setting changes. Also removes overnight bars: Pulse's
    /// setting promises pre/post, not 24-hour US trading.
    private func rebuildOnScreenCandles() {
        guard period.isMinuteK else {
            onScreenCandles = sourceCandles
            return
        }
        onScreenCandles = IntradayTradingSession.filterCandles(
            sourceCandles,
            market: symbol.market,
            includesExtendedHours: appState.showsExtendedHours(for: symbol)
        )
    }

    // MARK: - Chrome

    private var backButton: some View {
        IconButton(systemName: "chevron.left", help: PulseLocalization.localizedString("action.backHelp")) {
            route = .list
        }
    }

    private var titleCluster: some View {
        HStack(spacing: 6) {
            Text(appState.displayName(for: symbol))
                .font(.system(size: 13, weight: .semibold))
                .lineLimit(1)
                .truncationMode(.tail)
                .layoutPriority(1)
            MarketBadge(market: symbol.market)
                .fixedSize()
            Text(symbol.displayCode)
                .font(.system(size: 10).monospaced())
                .foregroundStyle(.secondary)
                .fixedSize()
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            backButton
            titleCluster
                .frame(maxWidth: .infinity, alignment: .leading)
            Spacer()
            if host == .menuBar {
                headerActions
            }
        }
        .overlay(alignment: .trailing) {
            if let shareFeedback {
                ShareFeedbackHUD(feedback: shareFeedback)
                    .padding(.trailing, host == .pinnedWindow ? 10 : (item?.supportsPosition == true ? 58 : 30))
                    .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .trailing)))
                    .allowsHitTesting(false)
            }
        }
        .padding(.horizontal, 12)
        // A standalone page header needs the panel's full inset, while the
        // pinned window already has a title bar immediately above it.
        .padding(.top, host == .pinnedWindow ? 2 : 7)
        .padding(.bottom, 7)
    }

    private var shareMenu: some View {
        ClusterMenu(
            systemName: "square.and.arrow.up",
            help: PulseLocalization.localizedString("action.share")
        ) {
            Button {
                copyShareImage()
            } label: {
                Label(
                    PulseLocalization.localizedString("action.copyAsImage"),
                    systemImage: "photo"
                )
            }
            .disabled(quote == nil || onScreenCandles.isEmpty)
            Button {
                copyShareText()
            } label: {
                Label(
                    PulseLocalization.localizedString("action.copyAsText"),
                    systemImage: "doc.text"
                )
            }
            .disabled(quote == nil)
        }
        .disabled(quote == nil)
        .opacity(quote == nil ? 0.45 : 1)
    }

    // MARK: - Onboarding tour

    /// Next on this stop performs the switch itself. The bubble goes first and
    /// the chart swaps a beat later, so the popover's dismissal never overlaps
    /// the content change — same sequencing as the list page's action steps.
    private var klineTourBubble: OnboardingTourBubble {
        OnboardingTourBubble(
            step: .kline,
            text: PulseLocalization.localizedString("onboarding.tour.kline")
        ) {
            appState.onboarding.completeStep(.kline)
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(180))
                period = .day
            }
        }
    }

    /// Same election as the list page: the pinned window carries the tour while
    /// it is up, else the panel does. The desktop window teaches through its own
    /// layout and never hosts the bubbles.
    private var isTourHost: Bool {
        switch host {
        case .pinnedWindow: true
        case .menuBar: !appState.settings.pinnedWindowVisible
        case .desktop: false
        }
    }

    private var klineTourBinding: Binding<Bool> {
        Binding(
            get: { isTourHost && appState.onboarding.activeTourStep == .kline },
            set: { presented in
                if !presented, appState.onboarding.activeTourStep == .kline {
                    appState.onboarding.pauseTour()
                }
            }
        )
    }

    /// Offers the candle stop once this page settles; the stop was queued by the
    /// detail step completing on the way in.
    private func maybeOfferKlineTourStep() {
        guard isTourHost,
              appState.onboarding.tourAvailable,
              appState.onboarding.activeTourStep == nil,
              appState.onboarding.tourResumeStep == .kline else { return }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(0.8))
            guard isTourHost,
                  appState.onboarding.tourAvailable,
                  appState.onboarding.activeTourStep == nil,
                  appState.onboarding.tourResumeStep == .kline else { return }
            appState.onboarding.beginTourIfNeeded()
        }
    }

    /// Opened from search without being watched: offer the add here so a lookup can
    /// graduate into the list without going back.
    private var addButton: some View {
        ClusterIcon(
            systemName: "star",
            help: PulseLocalization.localizedString(
                "search.addToGroup",
                appState.watchlist.selectedGroup?.name ?? ""
            )
        ) {
            addToWatchlist()
        }
    }

    /// Stable membership entry: the star mirrors the iOS detail page — outline
    /// adds to the selected group, filled removes from it.
    @ViewBuilder private var watchToggleButton: some View {
        if appState.watchlist.contains(symbol) {
            ClusterIcon(
                systemName: "star.fill",
                help: PulseLocalization.localizedString(
                    "watchlist.group.removeCurrent",
                    appState.watchlist.selectedGroup?.name ?? ""
                )
            ) {
                removeFromWatchlist()
            }
        } else {
            addButton
        }
    }

    /// Positions outlive watchlist membership, so the entry stays visible for
    /// every position-eligible instrument; tapping one that has no item yet
    /// materializes it (restoring dormant history) without list membership.
    private var symbolSupportsPosition: Bool {
        appState.supportsPosition(symbol)
    }

    @ViewBuilder private var positionButton: some View {
        let hasPosition = item?.hasPosition == true
        ClusterIcon(
            systemName: hasPosition ? "briefcase.fill" : "briefcase",
            help: PulseLocalization.localizedString(
                hasPosition ? "action.editPosition" : "action.addPosition"
            )
        ) {
            openPositions()
        }
    }

    @ViewBuilder private var headerActions: some View {
        shareMenu
        watchToggleButton
        if symbolSupportsPosition {
            positionButton
        }
    }

    /// The pinned window's title bar carries only page-level actions. Navigation and
    /// instrument identity stay in the page header below, where long names have room.
    @ViewBuilder private var toolbarActions: some View {
        Menu {
            Button {
                copyShareImage()
            } label: {
                Label(
                    PulseLocalization.localizedString("action.copyAsImage"),
                    systemImage: "photo"
                )
            }
            .disabled(quote == nil || onScreenCandles.isEmpty)
            Button {
                copyShareText()
            } label: {
                Label(
                    PulseLocalization.localizedString("action.copyAsText"),
                    systemImage: "doc.text"
                )
            }
            .disabled(quote == nil)
        } label: {
            Label(
                PulseLocalization.localizedString("action.share"),
                systemImage: "square.and.arrow.up"
            )
        }
        .menuIndicator(.hidden)
        .help(PulseLocalization.localizedString("action.share"))
        .disabled(quote == nil)

        if appState.watchlist.contains(symbol) {
            Button {
                removeFromWatchlist()
            } label: {
                Label(
                    PulseLocalization.localizedString(
                        "watchlist.group.removeCurrent",
                        appState.watchlist.selectedGroup?.name ?? ""
                    ),
                    systemImage: "star.fill"
                )
            }
            .help(PulseLocalization.localizedString(
                "watchlist.group.removeCurrent",
                appState.watchlist.selectedGroup?.name ?? ""
            ))
        } else {
            Button {
                addToWatchlist()
            } label: {
                Label(
                    PulseLocalization.localizedString(
                        "search.addToGroup",
                        appState.watchlist.selectedGroup?.name ?? ""
                    ),
                    systemImage: "star"
                )
            }
            .help(PulseLocalization.localizedString(
                "search.addToGroup",
                appState.watchlist.selectedGroup?.name ?? ""
            ))
        }

        if symbolSupportsPosition {
            Button {
                openPositions()
            } label: {
                Label(
                    PulseLocalization.localizedString(
                        (item?.hasPosition == true) ? "action.editPosition" : "action.addPosition"
                    ),
                    systemImage: (item?.hasPosition == true) ? "briefcase.fill" : "briefcase"
                )
            }
            .help(PulseLocalization.localizedString(
                (item?.hasPosition == true) ? "action.editPosition" : "action.addPosition"
            ))
        }
    }

    @MainActor
    private func addToWatchlist() {
        let info = SymbolInfo(
            symbol: symbol,
            name: appState.market.quote(for: symbol)?.name ?? appState.displayName(for: symbol)
        )
        appState.watchlist.add(info)
        appState.engine.poke()
    }

    @MainActor
    private func removeFromWatchlist() {
        appState.watchlist.remove(symbol)
    }

    /// Materializes a missing item (restoring dormant trade history) before the
    /// position hub opens: the hub and the ledger both require an item, but the
    /// instrument stays out of every list.
    @MainActor
    private func openPositions() {
        appState.prepareForPositionEditing(symbol)
        route = .position(symbol, .detail(symbol))
    }

    @MainActor
    private var sharedCandles: [Candle] {
        // K-line exports use exactly the zoomed window on screen; the intraday
        // chart keeps the full session, whose frame is its own context.
        let allCandles = onScreenCandles
        if period == .minute1 {
            return IntradayTrendSnapshot(
                candles: allCandles,
                market: symbol.market,
                includesExtendedHours: appState.showsExtendedHours(for: symbol)
            ).candles
        }
        return Array(allCandles[candleViewport.visibleRange(dataCount: allCandles.count)])
    }

    private var sharedInstrumentType: InstrumentType? {
        appState.instrumentType(for: symbol)
    }

    @MainActor
    private func copyShareImage() {
        do {
            let snapshot = DetailShareSnapshot(
                appState: appState,
                symbol: symbol,
                period: period,
                candles: sharedCandles
            )
            let palette = ChangePalette(redUp: snapshot.redUp)
            let card = PulseShareCard(
                ambientColor: snapshot.changeValue.map(palette.color(for:))
            ) {
                DetailShareContent(snapshot: snapshot)
            }
            let artifact = try ShareImageRenderer.render(
                card,
                configuration: .detailLandscape(
                    colorScheme: colorScheme,
                    locale: appState.settings.locale
                )
            )
            try ClipboardImageExporter.write(artifact)
            showShareFeedback(content: .image, isSuccess: true)
        } catch {
            showShareFeedback(content: .image, isSuccess: false)
        }
    }

    @MainActor
    private func copyShareText() {
        guard let quote else {
            showShareFeedback(content: .text, isSuccess: false)
            return
        }
        do {
            let snapshot = DetailTextSnapshot(
                symbol: symbol,
                name: appState.displayName(for: symbol),
                instrumentType: sharedInstrumentType,
                quote: quote,
                period: period,
                candles: sharedCandles,
                includesExtendedHours: appState.showsExtendedHours(for: symbol)
            )
            try ClipboardTextExporter.write(snapshot.renderedText())
            showShareFeedback(content: .text, isSuccess: true)
        } catch {
            showShareFeedback(content: .text, isSuccess: false)
        }
    }

    @MainActor
    private func showShareFeedback(content: ShareFeedback.Content, isSuccess: Bool) {
        let feedback = ShareFeedback(content: content, isSuccess: isSuccess)
        withAnimation(.snappy(duration: 0.2)) {
            shareFeedback = feedback
        }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(isSuccess ? 1.5 : 3))
            guard shareFeedback?.id == feedback.id else { return }
            withAnimation(.snappy(duration: 0.2)) {
                shareFeedback = nil
            }
        }
    }

    // MARK: - Hero

    private var heroSection: some View {
        HStack(alignment: .bottom, spacing: 12) {
            VStack(alignment: .leading, spacing: density == .compact ? 3 : 5) {
                if let quote {
                    let color = appState.palette.color(for: quote.change)
                    Text(quotePriceLabel(for: quote))
                        .font(.system(size: density.priceLabelSize, weight: .medium))
                        .foregroundStyle(.tertiary)
                    HStack(alignment: .firstTextBaseline, spacing: density == .compact ? 5 : 7) {
                        Text(PriceFormatter.price(quote.price, market: symbol.market))
                            .font(.system(size: density.priceSize, weight: .semibold).monospacedDigit())
                            .foregroundStyle(color)
                            // Animate the same magnitude the string prints so a third
                            // decimal the market allows stays in sync with the transition.
                            .contentTransition(
                                reduceMotion
                                    ? .opacity
                                    : .numericText(value: PriceFormatter.animatablePrice(
                                        quote.price,
                                        market: symbol.market
                                    ))
                            )
                            .animation(
                                .snappy(duration: 0.25),
                                value: PriceFormatter.animatablePrice(quote.price, market: symbol.market)
                            )
                            .lineLimit(1)
                            .minimumScaleFactor(0.82)
                        if let currency = quote.currencyCode {
                            Text(currency)
                                .font(.system(size: density.currencySize, weight: .semibold))
                                .foregroundStyle(.tertiary)
                        }
                    }
                    changePill(for: quote, color: color)
                    if let regularClose = regularCloseDisplay(for: quote) {
                        regularCloseRow(regularClose)
                            .padding(.top, 3)
                    }
                } else {
                    Text(PulseLocalization.localizedString("quote.price.current"))
                        .font(.system(size: density.priceLabelSize, weight: .medium))
                        .foregroundStyle(.tertiary)
                    Text("—")
                        .font(.system(size: density.priceSize, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
            }
            .layoutPriority(1)
            Spacer(minLength: 8)
            // The column is bottom-aligned to the price, so it grows upward:
            // the summary link goes on top, where arriving late pushes nothing
            // that was already there. On the desktop window the details column
            // owns that link — unless the column is hidden, where the hero is
            // the page's only way into the summary.
            VStack(alignment: .trailing, spacing: 6) {
                if symbol.isDescribable,
                   host != .desktop || !appState.settings.desktopDetailsVisible {
                    aboutLink
                }
                if let quote {
                    // Staleness is measured against the wall clock, so a frozen
                    // quote changes nothing the view observes — this block alone
                    // re-evaluates on a timer to let the label catch up.
                    TimelineView(.periodic(from: .now, by: 30)) { _ in
                        quoteMeta(for: quote)
                    }
                }
            }
        }
        .padding(.horizontal, density.horizontalPadding)
        .padding(.top, density == .compact ? 8 : 18)
    }

    /// The way into the business summary. It lives in the hero's annotation
    /// corner rather than as a block of text on the page: the summary is long,
    /// and a page whose quote already moves under the reader can't afford a
    /// late arrival reflowing it. Nothing is fetched to show this — the link is
    /// there for anything that could have a summary, and the page it opens does
    /// the asking.
    private var aboutLink: some View {
        Button {
            route = .profile(symbol)
        } label: {
            HStack(spacing: 2) {
                Text(PulseLocalization.localizedString("detail.section.about"))
                Image(systemName: "chevron.right")
                    .font(.system(size: density == .compact ? 7 : 9, weight: .semibold))
            }
            .font(.system(size: density.metaSize, weight: .medium))
            .foregroundStyle(.secondary)
            .contentShape(Rectangle())
        }
        .buttonStyle(.pressable)
    }

    /// The session's result as a tinted capsule — the same treatment the shared
    /// image gives it (arrow, percent, change), so the page and its export never
    /// disagree. Digits roll with each tick like the price above; a flat session
    /// keeps the capsule in the neutral secondary tint.
    private func changePill(for quote: Quote, color: Color) -> some View {
        let isCompact = density == .compact
        return HStack(spacing: 4) {
            if quote.change != 0 {
                Image(systemName: quote.change > 0 ? "arrowtriangle.up.fill" : "arrowtriangle.down.fill")
                    .font(.system(size: isCompact ? 7 : 9, weight: .bold))
            }
            Text(PriceFormatter.percent(quote.changePercent))
                .font(.system(size: density.changeSize, weight: .semibold).monospacedDigit())
                .contentTransition(reduceMotion ? .opacity : .numericText())
                .animation(.snappy(duration: 0.25), value: quote.changePercent)
            Text(PriceFormatter.change(quote.change, market: symbol.market))
                .font(.system(size: density.changeSize, weight: .medium).monospacedDigit())
                .opacity(0.9)
                .contentTransition(
                    reduceMotion
                        ? .opacity
                        : .numericText(value: PriceFormatter.animatablePrice(
                            quote.change,
                            market: symbol.market
                        ))
                )
                .animation(
                    .snappy(duration: 0.25),
                    value: PriceFormatter.animatablePrice(quote.change, market: symbol.market)
                )
        }
        .foregroundStyle(color)
        .lineLimit(1)
        .fixedSize(horizontal: true, vertical: false)
        .padding(.horizontal, isCompact ? 8 : 10)
        .padding(.vertical, isCompact ? 3 : 4)
        .background(
            color.opacity(0.13),
            in: RoundedRectangle(cornerRadius: isCompact ? 6 : 8, style: .continuous)
        )
    }

    /// Quote provenance at the hero's top-right: freshness, source, then market-time basis.
    /// Bottom-aligns with the price block so the metadata reads as an annotation to the quote.
    private func quoteMeta(for quote: Quote) -> some View {
        let delayText = appState.quoteDelayText(for: quote)
        let stallText = appState.quoteStallText(for: quote)
        // A stalled quote replaces the freshness labels outright: it explains the
        // frozen market time below better than "realtime" or the source's delay.
        let freshness = stallText ?? [delayText ?? PulseLocalization.localizedString("quote.realtime"),
                         appState.quoteCadenceText(for: quote)]
            .compactMap { $0 }
            .joined(separator: " · ")
        let isCurrent = delayText == nil && stallText == nil
        let dotSize: CGFloat = density == .compact ? 5 : 7
        return VStack(alignment: .trailing, spacing: density == .compact ? 4 : 5) {
            HStack(spacing: density == .compact ? 4 : 5) {
                Circle()
                    .fill(isCurrent ? Color.green.opacity(0.8) : .orange)
                    .frame(width: dotSize, height: dotSize)
                Text(freshness)
                    .foregroundStyle(isCurrent ? AnyShapeStyle(.tertiary) : AnyShapeStyle(Color.orange.opacity(0.85)))
            }
            if let sourceName = quote.sourceName {
                Text(sourceName)
                    .foregroundStyle(.tertiary)
            }
            Text(appState.quoteMarketTimeText(for: quote))
                .foregroundStyle(.tertiary)
                .monospacedDigit()
                // Market time ticks with real-time pushes; roll the digits like the price does.
                .contentTransition(reduceMotion ? .opacity : .numericText())
                .animation(.snappy(duration: 0.25), value: quote.timestamp)
        }
        .font(.system(size: density.metaSize, weight: .medium))
        .multilineTextAlignment(.trailing)
        .lineLimit(1)
        .minimumScaleFactor(0.8)
        .allowsTightening(true)
        .frame(maxWidth: density.metaMaxWidth, alignment: .trailing)
    }

    /// The last regular session's result, shown under the live extended-session
    /// price. Pre-market labels it "昨收" (that close was yesterday's); post and
    /// overnight label it "收盘" (today's just-finished session). During regular
    /// hours there is no "yesterday" to show and the row disappears.
    private func regularCloseDisplay(for quote: Quote) -> (label: String, close: Quote.RegularSessionClose)? {
        guard let regularSession = quote.regularSession else { return nil }
        switch quote.marketState {
        case .preMarket:
            return (PulseLocalization.localizedString("quote.regularClose.previous"), regularSession)
        case .postMarket, .overnight:
            return (PulseLocalization.localizedString("quote.regularClose.today"), regularSession)
        case .regular, .closed, .none:
            return nil
        }
    }

    private func regularCloseRow(_ display: (label: String, close: Quote.RegularSessionClose)) -> some View {
        let close = display.close
        let color = close.change.map { appState.palette.color(for: $0) }
        return HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(display.label)
                .font(.system(size: density.regularCloseLabelSize, weight: .medium))
                .foregroundStyle(.secondary)
            Text(PriceFormatter.price(close.price, market: symbol.market))
                .font(.system(size: density.regularClosePriceSize, weight: .semibold).monospacedDigit())
                .foregroundStyle(color ?? .secondary)
            if let change = close.change, let percent = close.changePercent {
                Text(PriceFormatter.change(change, market: symbol.market))
                    .font(.system(size: density.regularCloseChangeSize, weight: .medium).monospacedDigit())
                    .foregroundStyle(color ?? .secondary)
                Text(PriceFormatter.percent(percent))
                    .font(.system(size: density.regularCloseChangeSize, weight: .semibold).monospacedDigit())
                    .foregroundStyle(color ?? .secondary)
            }
        }
        .lineLimit(1)
        .minimumScaleFactor(0.8)
        .allowsTightening(true)
    }

    private func quotePriceLabel(for quote: Quote) -> String {
        switch quote.marketState {
        case .preMarket:
            PulseLocalization.localizedString("quote.price.preMarket")
        case .postMarket:
            PulseLocalization.localizedString("quote.price.postMarket")
        case .overnight:
            PulseLocalization.localizedString("quote.price.overnight")
        case .closed:
            PulseLocalization.localizedString("quote.price.close")
        case .regular, .none:
            PulseLocalization.localizedString("quote.price.current")
        }
    }

    // MARK: - Chart

    private var chartSection: some View {
        VStack(spacing: density == .compact ? 7 : 12) {
            chartHeader
            .padding(.horizontal, density.horizontalPadding)
            // Leading inset 2pt short of the text grid: the intraday plot's own 2pt inset
            // lands its edge on the grid; the trailing inset aligns the y-axis labels directly.
            chart
                .padding(.leading, density.horizontalPadding - 2)
                .padding(.trailing, density.horizontalPadding)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Keeps the period control compact when its labels fit, then gives it a full row for
    /// longer localizations instead of clipping or shrinking the text beyond readability.
    private var chartHeader: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) {
                sectionHeaderText(PulseLocalization.localizedString("detail.section.trend"))
                Spacer(minLength: 0)
                picker
                    .frame(width: density.periodPickerWidth)
            }

            VStack(alignment: .leading, spacing: 6) {
                sectionHeaderText(PulseLocalization.localizedString("detail.section.trend"))
                picker
            }
        }
    }

    private var picker: some View {
        let cornerRadius: CGFloat = density == .compact ? 6 : 8
        return HStack(spacing: density == .compact ? 4 : 5) {
            periodButton(.minute1)
            minutePeriodMenu
            periodButton(.day)
                .popover(isPresented: klineTourBinding, arrowEdge: .bottom) {
                    klineTourBubble
                }
            periodButton(.week)
            periodButton(.month)
        }
        .padding(density == .compact ? 2 : 3)
        .background(
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(Color.primary.opacity(colorScheme == .dark ? 0.09 : 0.055))
        )
        .overlay(
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .stroke(.separator.opacity(0.5), lineWidth: 0.5)
        )
        .accessibilityElement(children: .contain)
        .accessibilityLabel(PulseLocalization.localizedString("detail.period"))
    }

    private func periodButton(_ value: CandlePeriod) -> some View {
        Button {
            period = value
        } label: {
            periodControlLabel(value.displayName, isSelected: period == value)
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity)
        .help(value.displayName)
        .accessibilityAddTraits(period == value ? .isSelected : [])
    }

    private var minutePeriodMenu: some View {
        let selected = appState.settings.minuteCandlePeriod.isMinuteK
            ? appState.settings.minuteCandlePeriod
            : CandlePeriod.minute5
        return HStack(spacing: 0) {
            // Main segment action: return to the last chosen minute resolution.
            Button {
                period = selected
            } label: {
                Text(selected.displayName)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
                    .fixedSize(horizontal: true, vertical: false)
                    .frame(maxWidth: .infinity)
                    .frame(height: density.periodControlHeight)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .frame(maxWidth: .infinity)
            .help(selected.displayName)
            .accessibilityAddTraits(period.isMinuteK ? .isSelected : [])

            // Secondary action: only the small trailing chevron opens the resolution menu.
            Menu {
                ForEach(Self.minutePeriods, id: \.self) { value in
                    Button {
                        appState.settings.minuteCandlePeriod = value
                        period = value
                    } label: {
                        if value == selected {
                            Label(value.displayName, systemImage: "checkmark")
                        } else {
                            Text(value.displayName)
                        }
                    }
                }
            } label: {
                Image(systemName: "chevron.down")
                    .font(.system(size: density.periodChevronSize, weight: .semibold))
                    .frame(width: density.periodChevronWidth, height: density.periodControlHeight)
                    .contentShape(Rectangle())
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .help(selected.displayName)
        }
        .font(.system(size: density.periodFontSize, weight: period.isMinuteK ? .semibold : .medium))
        .foregroundStyle(period.isMinuteK ? .primary : .secondary)
        .frame(maxWidth: .infinity)
        .background {
            periodSelectionBackground(isSelected: period.isMinuteK)
        }
    }

    private func periodControlLabel(
        _ title: String,
        isSelected: Bool
    ) -> some View {
        Text(title)
            .lineLimit(1)
            .minimumScaleFactor(0.85)
            .fixedSize(horizontal: true, vertical: false)
            .font(.system(size: density.periodFontSize, weight: isSelected ? .semibold : .medium))
            .foregroundStyle(isSelected ? .primary : .secondary)
            .frame(maxWidth: .infinity)
            .frame(height: density.periodControlHeight)
            .contentShape(Rectangle())
            .background {
                periodSelectionBackground(isSelected: isSelected)
            }
    }

    @ViewBuilder
    private func periodSelectionBackground(isSelected: Bool) -> some View {
        if isSelected {
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(Color.primary.opacity(colorScheme == .dark ? 0.16 : 0.10))
                .overlay(
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .stroke(.separator.opacity(0.6), lineWidth: 0.5)
                )
        }
    }

    /// What the chart area shows. As the animation token this enum is what the
    /// declared transitions were missing: animating on bare emptiness never
    /// fired between the empty-state variants (no data ↔ failed ↔ spinner),
    /// because all of them keep the candle list empty.
    private enum ChartPhase: Equatable {
        /// The load for what is on screen came back with nothing.
        case noData
        /// The ask failed outright: a retry, not a verdict about the symbol's history.
        case loadFailed
        case loading
        /// Nothing yet: a load that answers inside the spinner's 150ms grace
        /// period goes straight to the chart.
        case waiting
        case minute1
        case candles
    }

    private var chartPhase: ChartPhase {
        if !onScreenCandles.isEmpty {
            return period == .minute1 ? .minute1 : .candles
        }
        if candlesKey == chartRequest { return .noData }
        if chartLoadFailed { return .loadFailed }
        if isLoading { return .loading }
        return .waiting
    }

    @ViewBuilder
    private var chart: some View {
        let phase = chartPhase
        ZStack {
            switch phase {
            case .noData:
                ContentUnavailableView {
                    Label(PulseLocalization.localizedString("chart.noData"), systemImage: "chart.xyaxis.line")
                } description: {
                    Text(PulseLocalization.localizedString("chart.noPeriodData", period.displayName))
                }
                .transition(.opacity)
            case .loadFailed:
                ContentUnavailableView {
                    Label(
                        PulseLocalization.localizedString("chart.loadFailed"),
                        systemImage: "wifi.exclamationmark"
                    )
                } description: {
                    Text(PulseLocalization.localizedString("chart.loadFailedHint"))
                } actions: {
                    Button(PulseLocalization.localizedString("action.retry")) {
                        chartRetryNonce += 1
                    }
                    .buttonStyle(.borderedProminent)
                }
                .transition(.opacity)
            case .loading:
                ChartLoadingView()
                    .transition(.opacity)
            case .waiting:
                EmptyView()
            case .minute1:
                IntradayChartView(
                    candles: sourceCandles,
                    previousClose: quote?.previousClose ?? sourceCandles.first?.open ?? 0,
                    market: symbol.market,
                    palette: appState.palette,
                    showsExtendedHours: appState.showsExtendedHours(for: symbol)
                )
                .transition(.opacity)
            case .candles:
                CandlestickChartView(
                    candles: onScreenCandles,
                    palette: appState.palette,
                    period: period,
                    market: symbol.market,
                    highlightsExtendedHours: period.isMinuteK
                        && appState.showsExtendedHours(for: symbol),
                    transactions: period == .day
                        ? item?.materializedTransactions() ?? []
                        : [],
                    currencyCode: currencyCode,
                    viewport: candleViewport
                )
                .transition(.opacity)
            }
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: chartPhase)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Position

    @ViewBuilder
    private var positionArea: some View {
        if PositionSummaryView.hasContent(for: symbol, in: appState) {
            sectionSeparator
            PositionSummaryView(symbol: symbol, density: density, onOpen: openPositions)
        } else {
            // Position sections supply this inset themselves. Keep the same
            // bottom breathing room when indices intentionally omit the section.
            Color.clear
                .frame(height: 12)
                .accessibilityHidden(true)
        }
    }

    // MARK: - Shared pieces

    private var sectionSeparator: some View {
        Divider()
            .opacity(0.45)
            .padding(.horizontal, density.horizontalPadding)
            .padding(.vertical, density.separatorVerticalPadding)
    }

    private func sectionHeaderText(_ title: String) -> some View {
        DetailSectionHeader(title: title, density: density)
    }
}
