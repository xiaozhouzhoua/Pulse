import SwiftUI
import PulseCore
import PulseUI

/// Type scale for the quote page. The menu bar panel and the pinned window share the
/// dense menu-bar scale; the desktop window is read from further away and has the room
/// to say the same things larger.
enum DetailDensity {
    case compact
    case regular

    init(host: PulseHost) {
        self = host == .desktop ? .regular : .compact
    }

    var horizontalPadding: CGFloat { self == .compact ? 12 : 20 }
    var sectionSpacing: CGFloat { self == .compact ? 8 : 12 }
    var separatorVerticalPadding: CGFloat { self == .compact ? 8 : 14 }

    var sectionHeaderFont: Font {
        self == .compact
            ? .system(size: 10, weight: .medium)
            : .system(size: 12, weight: .semibold)
    }
    var statLabelSize: CGFloat { self == .compact ? 9 : 11 }
    var statValueSize: CGFloat { self == .compact ? 10.5 : 13.5 }
    var pnlAmountSize: CGFloat { self == .compact ? 12.5 : 17 }
    var pnlPercentSize: CGFloat { self == .compact ? 10 : 12.5 }
    var noteSize: CGFloat { self == .compact ? 10.5 : 12.5 }
    var chevronSize: CGFloat { self == .compact ? 8 : 10 }

    var priceLabelSize: CGFloat { self == .compact ? 9 : 11.5 }
    var priceSize: CGFloat { self == .compact ? 28 : 42 }
    var currencySize: CGFloat { self == .compact ? 10 : 13 }
    var changeSize: CGFloat { self == .compact ? 12 : 17 }
    var metaSize: CGFloat { self == .compact ? 9 : 11 }
    var metaMaxWidth: CGFloat { self == .compact ? 132 : 260 }
    var regularCloseLabelSize: CGFloat { self == .compact ? 10 : 12 }
    var regularClosePriceSize: CGFloat { self == .compact ? 12 : 14.5 }
    var regularCloseChangeSize: CGFloat { self == .compact ? 11 : 13.5 }

    var periodFontSize: CGFloat { self == .compact ? 9 : 11.5 }
    var periodControlHeight: CGFloat { self == .compact ? 20 : 26 }
    var periodPickerWidth: CGFloat { self == .compact ? 260 : 380 }
    var periodChevronSize: CGFloat { self == .compact ? 5.5 : 7 }
    var periodChevronWidth: CGFloat { self == .compact ? 18 : 22 }
}

extension AppState {
    /// The watch item's type when one exists, otherwise what the symbol's identity
    /// alone implies; a symbol opened from search has no item yet.
    func instrumentType(for symbol: SymbolID) -> InstrumentType? {
        if let type = watchlist.item(for: symbol)?.resolvedInstrumentType { return type }
        if symbol.indexID != nil { return .index }
        if symbol.metalID != nil { return .commodity }
        if symbol.cryptoPair != nil { return .crypto }
        return nil
    }

    /// Positions outlive watchlist membership, so eligibility follows the instrument,
    /// not whether it is currently watched.
    func supportsPosition(_ symbol: SymbolID) -> Bool {
        switch instrumentType(for: symbol) {
        case .index, .commodity: false
        default: true
        }
    }

    /// The position hub and the ledger both require an item. A symbol without one gets
    /// it here (restoring dormant history) while staying out of every list.
    func prepareForPositionEditing(_ symbol: SymbolID) {
        guard watchlist.item(for: symbol) == nil else { return }
        watchlist.materializeItem(SymbolInfo(
            symbol: symbol,
            name: market.quote(for: symbol)?.name ?? displayName(for: symbol)
        ))
        engine.poke()
    }
}

/// Label above a value, the cell every quote and position grid is built from.
/// `color` carries a signed amount when the value should read as a gain or a loss;
/// without it the value stays neutral, like quantity or cost.
struct DetailStatCell: View {
    @Environment(AppState.self) private var appState
    let label: String
    let value: String?
    var color: Double?
    let density: DetailDensity

    var body: some View {
        VStack(alignment: .leading, spacing: density == .compact ? 2 : 3) {
            Text(label)
                .font(.system(size: density.statLabelSize))
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .allowsTightening(true)
            Text(value ?? "—")
                .font(.system(
                    size: density.statValueSize,
                    weight: color == nil ? .medium : .semibold
                ).monospacedDigit())
                .foregroundStyle(color.map { appState.palette.color(for: $0) } ?? .secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
                .allowsTightening(true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct DetailSectionHeader: View {
    let title: String
    let density: DetailDensity

    var body: some View {
        Text(title)
            .font(density.sectionHeaderFont)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
    }
}

/// Open, high, low, previous close, volume, turnover, and range for one symbol.
/// A Grid (not stacked HStacks) keeps the three value columns aligned, which is
/// what lets the amplitude row hand its remaining two columns to the range bar.
struct QuoteStatsView: View {
    @Environment(AppState.self) private var appState
    let symbol: SymbolID
    let density: DetailDensity

    var body: some View {
        let quote = appState.market.quote(for: symbol)
        let market = symbol.market
        VStack(alignment: .leading, spacing: density.sectionSpacing) {
            DetailSectionHeader(
                title: PulseLocalization.localizedString("detail.section.market"),
                density: density
            )
            Grid(
                alignment: .leading,
                horizontalSpacing: density.sectionSpacing,
                verticalSpacing: density.sectionSpacing
            ) {
                GridRow {
                    cell("stat.open", quote?.open.map { PriceFormatter.price($0, market: market) })
                    cell("stat.high", quote?.high.map { PriceFormatter.price($0, market: market) })
                    cell("stat.low", quote?.low.map { PriceFormatter.price($0, market: market) })
                }
                GridRow {
                    cell("stat.previousClose", quote.map { PriceFormatter.price($0.previousClose, market: market) })
                    cell("stat.volume", quote?.volume.map(PriceFormatter.compact))
                    cell("stat.turnover", quote?.turnover.map(PriceFormatter.compact))
                }
                GridRow {
                    cell("stat.amplitude", quote?.amplitudePercent.map(PriceFormatter.percentMagnitude))
                    if let quote, let range = QuoteDayRangePosition(quote: quote) {
                        QuoteDayRangeBar(position: range, change: quote.change, density: density)
                            .gridCellColumns(2)
                    }
                }
            }
        }
        .padding(.horizontal, density.horizontalPadding)
    }

    private func cell(_ key: String, _ value: String?) -> some View {
        DetailStatCell(label: PulseLocalization.localizedString(key), value: value, density: density)
    }
}

/// Where the live price sits between the session's low and high, as fractions of
/// that span. Fractions clamp to the span so a print outside a stale high/low
/// (the ranges and the price can come from different refreshes) parks at the
/// edge instead of escaping the track.
struct QuoteDayRangePosition: Equatable {
    var priceFraction: Double
    var previousCloseFraction: Double

    init?(price: Double, low: Double, high: Double, previousClose: Double) {
        guard low < high, price.isFinite, previousClose.isFinite else { return nil }
        func clamped(_ value: Double) -> Double {
            min(max((value - low) / (high - low), 0), 1)
        }
        self.priceFraction = clamped(price)
        self.previousCloseFraction = clamped(previousClose)
    }

    init?(quote: Quote) {
        guard let low = quote.low, let high = quote.high else { return nil }
        self.init(price: quote.price, low: low, high: high, previousClose: quote.previousClose)
    }
}

/// The session as a gauge: a thin low→high track with the previous close ticked
/// and the live price marked in its direction color. It sits beside the
/// amplitude figure it pictures, so the number and the position never disagree.
struct QuoteDayRangeBar: View {
    @Environment(AppState.self) private var appState
    @Environment(\.colorScheme) private var colorScheme
    let position: QuoteDayRangePosition
    let change: Double
    let density: DetailDensity

    private var trackHeight: CGFloat { density == .compact ? 4 : 5 }
    private var markerSize: CGFloat { density == .compact ? 8 : 10 }
    private var tickHeight: CGFloat { density == .compact ? 10 : 13 }

    var body: some View {
        GeometryReader { proxy in
            // The marker's center stays inside the track by half its own width,
            // so the usable span is what remains on either side of that inset.
            let usable = max(0, proxy.size.width - markerSize)
            ZStack {
                Capsule()
                    .fill(Color.primary.opacity(colorScheme == .dark ? 0.12 : 0.08))
                    .frame(height: trackHeight)
                // The previous close rides the same track: today's direction is
                // the marker's distance from this tick.
                Capsule()
                    .fill(.tertiary)
                    .frame(width: 1.5, height: tickHeight)
                    .position(
                        x: markerSize / 2 + usable * position.previousCloseFraction,
                        y: proxy.size.height / 2
                    )
                Circle()
                    .fill(appState.palette.color(for: change))
                    .frame(width: markerSize, height: markerSize)
                    .position(
                        x: markerSize / 2 + usable * position.priceFraction,
                        y: proxy.size.height / 2
                    )
            }
        }
        .frame(height: tickHeight)
        .animation(.snappy(duration: 0.25), value: position)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(PulseLocalization.localizedString("stat.dayRange"))
        .accessibilityValue(
            (position.priceFraction * 100)
                .rounded()
                .formatted(.number.precision(.fractionLength(0))) + "%"
        )
    }
}

/// The position block under a quote: an open position's P&L and size, a closed
/// one's realized result, or the prompt to record one. The whole block opens the
/// position hub, the same destination as the briefcase action.
struct PositionSummaryView: View {
    @Environment(AppState.self) private var appState
    let symbol: SymbolID
    let density: DetailDensity
    /// The panel ends its page with this block, so it carries the page's bottom
    /// inset; a column that continues below it spaces the next section itself.
    var insetsBottom = true
    let onOpen: () -> Void

    /// Whether this symbol has anything to show here. Indices and commodities only
    /// do when they carry a position recorded before they stopped being eligible.
    static func hasContent(for symbol: SymbolID, in appState: AppState) -> Bool {
        appState.supportsPosition(symbol) || appState.watchlist.item(for: symbol)?.hasPosition == true
    }

    private var item: WatchItem? { appState.watchlist.item(for: symbol) }
    private var quote: Quote? { appState.market.quote(for: symbol) }
    private var currencyCode: String? { quote?.currencyCode ?? symbol.currencyCode }

    /// Display driver: the live item when present, otherwise dormant history, so an
    /// instrument removed from every list keeps its records visible. Mutating goes
    /// through `onOpen`, whose caller materializes the item first.
    private var displayItem: WatchItem? {
        item ?? appState.watchlist.retainedHistoryItem(for: symbol)
    }

    var body: some View {
        Group {
            if appState.supportsPosition(symbol) {
                eligibleSection
            } else if let item, item.hasPosition {
                legacyIndexSection(item)
            }
        }
        .padding(.horizontal, density.horizontalPadding)
        .padding(.bottom, insetsBottom ? density.horizontalPadding : 0)
    }

    @ViewBuilder
    private var eligibleSection: some View {
        if let item = displayItem, item.hasPosition {
            Button(action: onOpen) {
                VStack(alignment: .leading, spacing: density.sectionSpacing) {
                    HStack(spacing: 4) {
                        header
                        Spacer(minLength: 0)
                        chevron
                    }
                    if let quote, let metrics = PositionMetrics(item: item, quote: quote) {
                        HStack(spacing: density.sectionSpacing) {
                            pnlCell("metric.todayPnL", amount: metrics.todayPnL, percent: metrics.todayReturnPercent)
                            pnlCell("metric.totalPnL", amount: metrics.totalPnL, percent: metrics.totalReturnPercent)
                        }
                        HStack(spacing: density.sectionSpacing) {
                            cell("position.quantity", PriceFormatter.quantity(metrics.quantity))
                            cell("position.cost", PriceFormatter.price(metrics.averageCost))
                            cell("position.marketValue", PriceFormatter.money(metrics.marketValue, currencyCode: currencyCode))
                        }
                    } else {
                        note(PulseLocalization.localizedString("position.waitingQuote"))
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.pressable)
        } else if let item = displayItem, item.hasPositionHistory {
            // Selling out is not the same as never having held: the trade log and
            // what it realized outlive the position, and dropping straight back to
            // "no position" would read as if the record was lost.
            Button(action: onOpen) {
                VStack(alignment: .leading, spacing: density.sectionSpacing) {
                    HStack(spacing: 4) {
                        header
                        Text(PulseLocalization.localizedString("position.closed"))
                            .font(.system(size: density.statLabelSize, weight: .medium))
                            .foregroundStyle(.tertiary)
                        Spacer(minLength: 0)
                        chevron
                    }
                    HStack(spacing: density.sectionSpacing) {
                        DetailStatCell(
                            label: PulseLocalization.localizedString("position.realizedPnL"),
                            value: PriceFormatter.signedMoney(item.realizedPnL, currencyCode: currencyCode),
                            color: item.realizedPnL,
                            density: density
                        )
                        cell(
                            "position.historyTrades",
                            PulseLocalization.localizedString("position.tradeCount", item.transactions.count)
                        )
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.pressable)
        } else {
            VStack(alignment: .leading, spacing: density.sectionSpacing) {
                header
                HStack {
                    note(PulseLocalization.localizedString("position.notSet"))
                    Spacer()
                    Button(PulseLocalization.localizedString("action.addPosition"), action: onOpen)
                        .buttonStyle(.pressable)
                        .font(.system(size: density.noteSize, weight: .medium))
                        .foregroundStyle(.tint)
                }
            }
        }
    }

    private func legacyIndexSection(_ item: WatchItem) -> some View {
        VStack(alignment: .leading, spacing: density.sectionSpacing) {
            header
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                note(PulseLocalization.localizedString("position.indexLegacyNotice"))
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                Button(PulseLocalization.localizedString("action.clearPosition"), role: .destructive) {
                    appState.watchlist.clearPosition(symbol)
                }
                .buttonStyle(.pressable)
                .font(.system(size: density.noteSize, weight: .medium))
            }
        }
    }

    private var header: some View {
        DetailSectionHeader(
            title: PulseLocalization.localizedString("detail.section.position"),
            density: density
        )
    }

    private var chevron: some View {
        Image(systemName: "chevron.right")
            .font(.system(size: density.chevronSize, weight: .semibold))
            .foregroundStyle(.tertiary)
    }

    private func note(_ text: String) -> some View {
        Text(text)
            .font(.system(size: density.noteSize))
            .foregroundStyle(.tertiary)
    }

    private func cell(_ key: String, _ value: String?) -> some View {
        DetailStatCell(label: PulseLocalization.localizedString(key), value: value, density: density)
    }

    /// Signed amount with its percent on a shared baseline, tinted by direction.
    private func pnlCell(_ key: String, amount: Double, percent: Double) -> some View {
        VStack(alignment: .leading, spacing: density == .compact ? 2 : 3) {
            Text(PulseLocalization.localizedString(key))
                .font(.system(size: density.statLabelSize))
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .allowsTightening(true)
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Text(PriceFormatter.signedMoney(amount, currencyCode: currencyCode))
                    .font(.system(size: density.pnlAmountSize, weight: .semibold).monospacedDigit())
                Text(PriceFormatter.percent(percent))
                    .font(.system(size: density.pnlPercentSize, weight: .medium).monospacedDigit())
                    .opacity(0.9)
            }
            .foregroundStyle(appState.palette.color(for: amount))
            .lineLimit(1)
            .minimumScaleFactor(0.75)
            .allowsTightening(true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
