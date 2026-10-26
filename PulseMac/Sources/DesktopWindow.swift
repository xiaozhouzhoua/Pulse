import AppKit
import SwiftUI
import PulseCore

/// The main window: the watchlist as a sidebar, the selected symbol's quote and chart
/// across the middle, and its stats and position in a details column on the right.
@MainActor
enum DesktopWindow {
    static let id = "quote.desktop"
    /// 16:9, and small enough to open without filling any current Mac display at its
    /// default scaling.
    static let defaultSize = CGSize(width: 1280, height: 720)
    /// The same ratio at the smallest size where sidebar, chart, and details column
    /// all keep a usable width.
    static let minimumSize = CGSize(width: 1024, height: 576)
    /// The width every pushed page (position, trade, log, profile) was laid out for,
    /// so they slot into the column unchanged.
    static let detailsWidth: CGFloat = 340

    static func activate() {
        // Same reasoning as the pinned window: a cooperative activate is refused
        // when the request comes from the menu bar panel of an inactive app.
        NSApp.activate(ignoringOtherApps: true)
        DispatchQueue.main.async {
            NSApp.activate(ignoringOtherApps: true)
            NSApp.windows.first { $0.identifier?.rawValue.hasPrefix(id) == true }?.makeKeyAndOrderFront(nil)
        }
    }
}

extension PopoverRoute {
    /// The instrument a page is about; nil for the list and the settings pages.
    var symbol: SymbolID? {
        switch self {
        case .detail(let symbol), .profile(let symbol),
             .position(let symbol, _), .trade(let symbol, _, _), .editTrade(let symbol, _, _),
             .transactions(let symbol, _), .calibrate(let symbol, _):
            symbol
        case .list, .settings, .providerList, .providerDetail, .dataSettings,
             .appearanceSettings, .mcpSettings:
            nil
        }
    }

    var isSettingsPage: Bool {
        switch self {
        case .settings, .providerList, .providerDetail, .dataSettings,
             .appearanceSettings, .mcpSettings:
            true
        default:
            false
        }
    }

    /// Pages the desktop window shows in its details column rather than in place
    /// of the quote.
    var isDetailsPage: Bool {
        switch self {
        case .position, .trade, .editTrade, .transactions, .calibrate, .profile:
            true
        default:
            false
        }
    }
}

struct DesktopRootView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Shared with the sidebar and the detail pages, which navigate by setting it
    /// exactly as they do in the panel. Here a symbol route selects that symbol, and
    /// a position, trade, log, or profile route opens in the details column.
    @State private var route: PopoverRoute = .list
    @State private var searchSession = SearchSession()

    var body: some View {
        NavigationSplitView {
            WatchlistView(route: $route, searchSession: $searchSession, selectedSymbol: selectedSymbol)
                .navigationSplitViewColumnWidth(min: 280, ideal: 310, max: 420)
        } detail: {
            detail
        }
        .frame(minWidth: DesktopWindow.minimumSize.width, minHeight: DesktopWindow.minimumSize.height)
        .background {
            EscapeBackMonitor {
                // Search owns Escape while it is up: its field clears, then closes.
                guard !searchSession.isActive,
                      let previous = previousRoute(for: displayRoute) else { return false }
                route = previous
                return true
            }
        }
        .background {
            ArrowKeyMonitor { offset in
                guard !searchSession.isActive else { return false }
                return moveSelection(by: offset)
            }
        }
        .onChange(of: route) { oldRoute, newRoute in
            if newRoute.isSettingsPage {
                // Settings has its own window; the page underneath stays put.
                route = oldRoute.isSettingsPage ? .list : oldRoute
                openSettings()
                return
            }
            if let symbol = newRoute.symbol, symbol != appState.settings.desktopSelectedSymbol {
                appState.settings.desktopSelectedSymbol = symbol
            }
            if newRoute.isDetailsPage, !appState.settings.desktopDetailsVisible {
                appState.settings.desktopDetailsVisible = true
            }
        }
        .onAppear {
            appState.setHostVisible(.desktop, true)
            // This window is the first thing a new install sees; the floating
            // welcome window it replaces must not follow it up.
            appState.onboarding.markSeen(.welcomeWindow)
            // The menu bar label normally installs this, but a user can hide the
            // item in System Settings, and then its label never appears.
            if AppDelegate.reopenHandler == nil {
                AppDelegate.reopenHandler = { [openWindow] in
                    openWindow(id: DesktopWindow.id)
                    DesktopWindow.activate()
                }
            }
        }
        .onDisappear {
            appState.setHostVisible(.desktop, false)
            searchSession.text = ""
            searchSession.isActive = false
        }
        .onChange(of: appState.watchlist.symbols) { _, _ in
            appState.watchlistSymbolsChanged()
        }
        .onChange(of: appState.watchlist.groups.map(\.id)) { _, _ in
            appState.watchlistGroupsChanged()
        }
    }

    /// The route's own symbol when it names one, else the last one shown (kept
    /// across launches), else the top of the current list.
    private var selectedSymbol: SymbolID? {
        route.symbol
            ?? appState.settings.desktopSelectedSymbol
            ?? displayedItems.first?.symbol
    }

    /// A details page whose position has gone (its symbol left every list, or the
    /// trade being edited was deleted) falls back to where it came from.
    private var displayRoute: PopoverRoute {
        switch route {
        case .position(let symbol, _), .trade(let symbol, _, _),
             .transactions(let symbol, _), .calibrate(let symbol, _):
            return appState.watchlist.item(for: symbol) == nil ? .detail(symbol) : route
        case .editTrade(let symbol, let id, let returnRoute):
            guard let item = appState.watchlist.item(for: symbol) else { return .detail(symbol) }
            return item.transactions.contains(where: { $0.id == id })
                ? route
                : .transactions(symbol, returnRoute)
        default:
            return route
        }
    }

    private var displayedItems: [WatchItem] {
        WatchlistDisplayOrder.items(
            from: appState.watchlist,
            prioritizeOpenMarkets: appState.settings.prioritizeOpenMarkets
        )
    }

    @ViewBuilder
    private var detail: some View {
        if let symbol = selectedSymbol {
            HStack(spacing: 0) {
                DetailView(symbol: symbol, route: $route)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                if appState.settings.desktopDetailsVisible {
                    Divider()
                    DesktopDetailsColumn(symbol: symbol, page: displayRoute, route: $route)
                        .frame(width: DesktopWindow.detailsWidth)
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                }
            }
            .animation(
                reduceMotion ? nil : .snappy(duration: 0.25),
                value: appState.settings.desktopDetailsVisible
            )
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    detailsToggle
                }
            }
        } else {
            placeholder
                .navigationTitle(Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String ?? "Tick")
        }
    }

    private var detailsToggle: some View {
        let isVisible = appState.settings.desktopDetailsVisible
        let label = PulseLocalization.localizedString(isVisible ? "desktop.details.hide" : "desktop.details.show")
        return Button {
            appState.settings.desktopDetailsVisible.toggle()
        } label: {
            Label(label, systemImage: "sidebar.trailing")
        }
        .help(label)
    }

    private var placeholder: some View {
        let isEmpty = appState.watchlist.allItems.isEmpty
        return ContentUnavailableView {
            Label(
                PulseLocalization.localizedString(isEmpty ? "empty.watchlist" : "desktop.placeholder.title"),
                systemImage: "chart.line.uptrend.xyaxis"
            )
        } description: {
            Text(PulseLocalization.localizedString("desktop.placeholder.message"))
        } actions: {
            Button {
                searchSession.focusRequest += 1
            } label: {
                Label(PulseLocalization.localizedString("empty.searchButton"), systemImage: "magnifyingglass")
            }
            .prominentButtonStyle()
        }
    }

    private func previousRoute(for route: PopoverRoute) -> PopoverRoute? {
        switch route {
        case .position(_, let returnRoute):
            returnRoute.popoverRoute
        case .trade(let symbol, _, let returnRoute),
             .transactions(let symbol, let returnRoute),
             .calibrate(let symbol, let returnRoute):
            .position(symbol, returnRoute)
        case .editTrade(let symbol, _, let returnRoute):
            .transactions(symbol, returnRoute)
        case .profile(let symbol):
            .detail(symbol)
        default:
            nil
        }
    }

    /// Up and down step through the list in the order the sidebar shows it, the way
    /// a desktop master-detail list reads.
    private func moveSelection(by offset: Int) -> Bool {
        let items = displayedItems
        guard !items.isEmpty else { return false }
        let next: Int
        if let symbol = selectedSymbol, let current = items.firstIndex(where: { $0.symbol == symbol }) {
            next = min(max(current + offset, 0), items.count - 1)
            guard next != current else { return true }
        } else {
            next = offset > 0 ? 0 : items.count - 1
        }
        route = .detail(items[next].symbol)
        return true
    }
}

/// The right-hand column: the selected symbol's stats and position at rest, and the
/// pages pushed from them (position hub, trade entry, trade log, quick set, profile),
/// which keep the chart in view while they are open.
struct DesktopDetailsColumn: View {
    @Environment(AppState.self) private var appState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let symbol: SymbolID
    let page: PopoverRoute
    @Binding var route: PopoverRoute

    private var pushTransition: AnyTransition {
        reduceMotion
            ? .opacity
            : .asymmetric(
                insertion: .move(edge: .trailing).combined(with: .opacity),
                removal: .move(edge: .trailing).combined(with: .opacity)
            )
    }

    var body: some View {
        ZStack(alignment: .top) {
            switch page {
            case .position(let symbol, let returnRoute):
                PositionHubView(symbol: symbol, returnRoute: returnRoute, route: $route)
                    .transition(pushTransition)
            case .trade(let symbol, let side, let returnRoute):
                TradeEntryView(symbol: symbol, side: side, returnRoute: returnRoute, route: $route)
                    .transition(pushTransition)
            case .editTrade(let symbol, let id, let returnRoute):
                if let transaction = appState.watchlist.item(for: symbol)?
                    .transactions.first(where: { $0.id == id }) {
                    TradeEntryView(symbol: symbol, editing: transaction, returnRoute: returnRoute, route: $route)
                        .transition(pushTransition)
                }
            case .transactions(let symbol, let returnRoute):
                TransactionListView(symbol: symbol, returnRoute: returnRoute, route: $route)
                    .transition(pushTransition)
            case .calibrate(let symbol, let returnRoute):
                PositionCalibrationPage(symbol: symbol, returnRoute: returnRoute, route: $route)
                    .transition(pushTransition)
            case .profile(let symbol):
                ProfileView(symbol: symbol, route: $route)
                    .transition(pushTransition)
            default:
                DesktopQuoteSummary(symbol: symbol, route: $route)
                    .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .clipped()
        .animation(reduceMotion ? nil : .snappy(duration: 0.24), value: page)
    }
}

/// The details column at rest: market stats, the position, and the way into the
/// business summary.
private struct DesktopQuoteSummary: View {
    @Environment(AppState.self) private var appState
    let symbol: SymbolID
    @Binding var route: PopoverRoute

    private let density = DetailDensity.regular

    var body: some View {
        let showsPosition = PositionSummaryView.hasContent(for: symbol, in: appState)
        // The about row closes the column with its own inset; otherwise the last
        // section has to carry the bottom breathing room itself.
        let showsAbout = symbol.isDescribable
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                QuoteStatsView(symbol: symbol, density: density)
                    .padding(.top, 18)
                if showsPosition {
                    separator
                    PositionSummaryView(symbol: symbol, density: density, insetsBottom: !showsAbout) {
                        appState.prepareForPositionEditing(symbol)
                        route = .position(symbol, .detail(symbol))
                    }
                }
                if showsAbout {
                    separator
                    aboutRow
                } else if !showsPosition {
                    Color.clear
                        .frame(height: density.horizontalPadding)
                        .accessibilityHidden(true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollIndicators(.automatic, axes: .vertical)
        .softScrollEdgeEffect(for: .vertical)
    }

    private var separator: some View {
        Divider()
            .opacity(0.45)
            .padding(.horizontal, density.horizontalPadding)
            .padding(.vertical, density.separatorVerticalPadding)
    }

    private var aboutRow: some View {
        Button {
            route = .profile(symbol)
        } label: {
            HStack(spacing: 4) {
                DetailSectionHeader(
                    title: PulseLocalization.localizedString("detail.section.about"),
                    density: density
                )
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.system(size: density.chevronSize, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.pressable)
        .padding(.horizontal, density.horizontalPadding)
        .padding(.bottom, density.horizontalPadding)
    }
}

/// The Settings window (⌘,): the same settings pages as the panel, navigated in
/// place, at a width that gives their forms room.
struct SettingsWindowRoot: View {
    @Environment(AppState.self) private var appState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var route: PopoverRoute = .settings

    static let size = CGSize(width: 460, height: 620)

    private var pushTransition: AnyTransition {
        reduceMotion
            ? .opacity
            : .asymmetric(
                insertion: .move(edge: .trailing).combined(with: .opacity),
                removal: .move(edge: .trailing).combined(with: .opacity)
            )
    }

    var body: some View {
        ZStack(alignment: .top) {
            switch route {
            case .providerList(let kind):
                ProviderListView(kind: kind, route: $route)
                    .transition(pushTransition)
            case .providerDetail(let id):
                ProviderDetailPage(id: id, route: $route)
                    .transition(pushTransition)
            case .dataSettings:
                DataSettingsView(route: $route)
                    .transition(pushTransition)
            case .appearanceSettings:
                AppearanceSettingsView(route: $route)
                    .transition(pushTransition)
            case .mcpSettings:
                MCPSettingsView(route: $route)
                    .transition(pushTransition)
            default:
                SettingsView(route: $route)
            }
        }
        .frame(width: Self.size.width, height: Self.size.height, alignment: .top)
        .clipped()
        .animation(reduceMotion ? nil : .snappy(duration: 0.24), value: route)
        .background {
            EscapeBackMonitor {
                guard let previous = previousRoute(for: route) else { return false }
                route = previous
                return true
            }
        }
        .onChange(of: route) { _, newRoute in
            // The settings pages are the only destinations in this window; a page
            // asking to leave them returns to the root instead.
            if !newRoute.isSettingsPage { route = .settings }
        }
        .onDisappear { route = .settings }
    }

    private func previousRoute(for route: PopoverRoute) -> PopoverRoute? {
        switch route {
        case .providerList, .dataSettings, .appearanceSettings, .mcpSettings:
            .settings
        case .providerDetail(let id):
            .providerList(appState.providerListKind(for: id))
        default:
            nil
        }
    }
}

/// Arrow keys for the window's list, taken before the focused control sees them
/// unless that control is editing text.
private struct ArrowKeyMonitor: NSViewRepresentable {
    /// -1 for up, +1 for down; returns whether the press was used.
    let onArrow: (Int) -> Bool

    func makeNSView(context: Context) -> ArrowKeyMonitorView {
        let view = ArrowKeyMonitorView()
        view.onArrow = onArrow
        return view
    }

    func updateNSView(_ view: ArrowKeyMonitorView, context: Context) {
        view.onArrow = onArrow
    }

    static func dismantleNSView(_ view: ArrowKeyMonitorView, coordinator: ()) {
        view.removeMonitor()
    }
}

@MainActor
private final class ArrowKeyMonitorView: NSView {
    var onArrow: (Int) -> Bool = { _ in false }
    private var monitor: Any?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        removeMonitor()
        guard let hostWindow = window else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self, weak hostWindow] event in
            guard let self, let hostWindow, event.window === hostWindow,
                  // Arrow keys always carry the function and keypad flags; any real
                  // modifier means a different shortcut.
                  event.modifierFlags.intersection(.deviceIndependentFlagsMask)
                      .subtracting([.function, .numericPad]).isEmpty,
                  !(hostWindow.firstResponder is NSText) else { return event }
            switch event.keyCode {
            case 125: return self.onArrow(1) ? nil : event
            case 126: return self.onArrow(-1) ? nil : event
            default: return event
            }
        }
    }

    func removeMonitor() {
        guard let monitor else { return }
        NSEvent.removeMonitor(monitor)
        self.monitor = nil
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }
}
