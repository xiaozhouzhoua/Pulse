import AppKit
import SwiftUI
import PulseCore
import PulseUI

/// Receives custom-scheme URLs (the Longbridge OAuth callback). The window that started
/// the authorization may be closed by the time the browser redirects back, so the app
/// delegate is the reliable entry point rather than `onOpenURL`.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    static var urlHandler: ((URL) -> Void)?
    static private(set) var isTerminating = false
    /// Clicking the Dock icon, or launching the running app again (Applications
    /// double-click, Spotlight), brings the main window back even while the floating
    /// window is up: that window is an accessory to the main one, not a stand-in.
    static var reopenHandler: (() -> Void)?

    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            Self.urlHandler?(url)
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        Self.isTerminating = true
        return .terminateNow
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        Self.reopenHandler?()
        return false
    }

    /// Closing the main window leaves the menu bar item and the Dock icon running,
    /// the way a quote ticker is expected to keep going.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}

@main
struct PulseMacApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var appState: AppState

    init() {
        SelfTest.runIfRequested()
        SoftwareUpdateController.shared.start()
        let state = AppState()
        PulseTelemetry.configure(collectionEnabled: state.settings.shareAnonymousUsageData)
        PulseTelemetry.signal(.appLaunched)
        // The main window opens at every launch and is what a new install sees first,
        // so the floating welcome window of the menu-bar-only app never presents.
        state.onboarding.welcomeSessionActive = false
        _appState = State(initialValue: state)
        AppDelegate.urlHandler = { url in state.handleOAuthCallback(url) }
    }

    private static var displayName: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String ?? "Tick"
    }

    var body: some Scene {
        // First on purpose: SwiftUI presents the first window scene at launch, which
        // is what makes this the app's main window.
        desktopWindow

        MenuBarExtra {
            PopoverRootView()
                .environment(appState)
                .environment(\.locale, appState.settings.locale)
                .environment(\.pulseHost, .menuBar)
                .background(.thickMaterial)
        } label: {
            MenuBarLabel(appState: appState)
        }
        .menuBarExtraStyle(.window)

        pinnedWindowBase

        Settings {
            SettingsWindowRoot()
                .environment(appState)
                .environment(\.locale, appState.settings.locale)
                .environment(\.pulseHost, .desktop)
        }
    }

    private var desktopWindow: some Scene {
        Window(Self.displayName, id: DesktopWindow.id) {
            DesktopRootView()
                .environment(appState)
                .environment(\.locale, appState.settings.locale)
                .environment(\.pulseHost, .desktop)
        }
        .defaultSize(width: DesktopWindow.defaultSize.width, height: DesktopWindow.defaultSize.height)
        .windowResizability(.contentMinSize)
        .commands {
            QuoteCommands(appState: appState)
        }
    }

    private var pinnedWindowBase: some Scene {
        // The pinned host: the same view tree in a floating window that outlives losing
        // focus. Sized by its content, so route pushes resize the window exactly the way
        // they resize the panel.
        // Deliberately title-less. The title bar is the Mac-native home for a window's
        // identity, but at 340pt wide there is not room for both a title and the action
        // group: macOS collapses the whole toolbar into a `»` overflow button, burying
        // four one-click actions in a submenu. The actions win; the app's identity is
        // already carried by the Dock icon and the menu bar item.
        Window("Tick", id: PinnedWindow.id) {
            PinnedWindowHost(settings: appState.settings) {
                PopoverRootView()
                    .environment(appState)
                    .environment(\.locale, appState.settings.locale)
                    .environment(\.pulseHost, .pinnedWindow)
                    .windowContainerBackgroundCompat()
                    .onAppear {
                        appState.settings.pinnedWindowVisible = true
                        if appState.onboarding.welcomeSessionActive {
                            appState.onboarding.markSeen(.welcomeWindow)
                            // An accessory app is not frontmost at launch, so the
                            // welcome window would otherwise come up behind whatever
                            // the user was working in.
                            PinnedWindow.activate()
                        }
                    }
                    .onDisappear {
                        guard !AppDelegate.isTerminating else {
                            // Quit is not a close: the pin survives to the next launch.
                            return
                        }
                        appState.settings.pinnedWindowVisible = false
                        appState.onboarding.welcomeSessionActive = false
                        // A tour interrupted by the window closing resumes at the
                        // same stop in whichever host shows the list next.
                        appState.onboarding.pauseTour()
                    }
            }
        }
        // Not `.plain`: it would drop the empty 32pt title bar strip and give the panel's
        // header the window's first row, but a plain window is borderless, and AppKit
        // will not make a borderless window key. Verified on macOS 26: the search field
        // ignores every keystroke, Cmd-W and Cmd-C are dead, and clicking the window
        // never brings the app forward. Forcing `fullSizeContentView` under a titled
        // style does not help either — SwiftUI lays scene content out below the title bar
        // regardless. The strip stays; it is also the drag handle and close button.
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
        // Both windows are titled with the app's name; listing this one in the
        // Window menu too would offer two identical entries. The pin and the menu
        // bar item are its ways in.
        .commandsRemoved()
    }

}

/// Menu commands for the regular app: the sidebar toggle, refresh, and a way back to
/// the main window. Settings… (⌘,) comes with the Settings scene.
struct QuoteCommands: Commands {
    let appState: AppState
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        SidebarCommands()
        CommandGroup(after: .sidebar) {
            Button(PulseLocalization.localizedString("action.refreshNow")) {
                PulseTelemetry.signal(.manualRefreshRequested)
                appState.engine.poke()
            }
            .keyboardShortcut("r", modifiers: .command)
        }
        CommandGroup(before: .windowList) {
            Button(PulseLocalization.localizedString("action.openMainWindow")) {
                openWindow(id: DesktopWindow.id)
                DesktopWindow.activate()
            }
            .keyboardShortcut("0", modifiers: .command)
            Divider()
        }
    }
}

struct MenuBarLabel: View {
    let appState: AppState
    @Environment(\.openWindow) private var openWindow
    @State private var didApplyInitialWindowPresentation = false

    private var templateIcon: NSImage {
        let canvasSize = NSSize(width: 16, height: 16)
        guard let source = NSImage(named: "PulseMenuBarIcon") else {
            let fallback = NSImage(
                systemSymbolName: "waveform.path.ecg",
                accessibilityDescription: "Tick"
            ) ?? NSImage(size: canvasSize)
            fallback.size = canvasSize
            fallback.isTemplate = true
            return fallback
        }

        let image = NSImage(size: canvasSize, flipped: false) { rect in
            let aspectRatio = source.size.width / source.size.height
            let waveformHeight = rect.width / aspectRatio
            source.draw(
                in: NSRect(
                    x: rect.minX,
                    y: rect.midY - waveformHeight / 2,
                    width: rect.width,
                    height: waveformHeight
                ),
                from: .zero,
                operation: .sourceOver,
                fraction: 1
            )
            return true
        }
        image.isTemplate = true
        return image
    }

    var body: some View {
        Group {
            // Icon only by default; price text appears only after the user enables "show quotes in menu bar" in settings
            if !appState.settings.showPriceInMenuBar || appState.watchlist.isEmpty {
                Image(nsImage: templateIcon)
                    .accessibilityLabel("Tick")
            } else {
                Text(appState.menuBarText)
                    .font(.system(size: 12).monospacedDigit())
            }
        }
        // The label is the one view alive for the app's whole lifetime, which makes it
        // the only reliable place to hand the AppKit delegate a scene-scoped action.
        .onAppear {
            AppDelegate.reopenHandler = {
                openWindow(id: DesktopWindow.id)
                DesktopWindow.activate()
            }
            guard !didApplyInitialWindowPresentation else { return }
            didApplyInitialWindowPresentation = true
            // The main window presents itself; only a floating window left pinned
            // at the last quit needs bringing back.
            guard appState.settings.pinnedWindowVisible else { return }
            openWindow(id: PinnedWindow.id)
        }
    }
}
