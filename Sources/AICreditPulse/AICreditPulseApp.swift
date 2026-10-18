import AICreditPulseCore
import ServiceManagement
import SwiftUI

/// AI CreditPulse — menu bar agent (LSUIElement, no Dock icon). Pure AppKit
/// lifecycle (@main on the delegate): with no SwiftUI scenes in play there is
/// no scene-window restoration, so no ghost "Settings"/stub window can pop up
/// alongside the real program window at launch. The status item and the main
/// window are assembled here, explicitly: the window closes without touching
/// the agent, and Quit ends the whole process.
@main
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var refreshTask: Task<Void, Never>?
    private var timer: Timer?
    private let status = StatusBarController()
    private var mainWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Populate the default .env skeleton on first launch (never overwrites
        // existing keys) so the window and the file agree from the start.
        Task.detached {
            try? EnvStore.shared.update([
                "OPENROUTER_API_KEY": "",
                "DEEPSEEK_API_KEY": "",
                "GLM_API_KEY": "",
                "CLAUDE_CODE_OAUTH_TOKEN": "",
                "ILMU_CONSOLE_COOKIE": "",
                "HERMES_CUSTOM_ILMU_COOKIE": "",
                "OPENCODE_API_KEY": "",
                "NOUS_PORTAL_TOKEN": "",
            ])
        }

        status.install(openMain: { [weak self] in self?.showMainWindow() })

        // First pull after launch.
        refreshTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(600))
            await self?.pull()
        }
        refreshTimer()
        // .env edits change keys without restarts; re-status with them.
        NotificationCenter.default.addObserver(
            forName: .envStoreDidChange, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in await self?.pull() }
        }

        // Launch policy: the window pops up on a normal launch; an automatic
        // launch at restart stays hidden when the user opted into that.
        if shouldShowWindowAtLaunch() {
            showMainWindow()
        }
    }

    /// A launch counts as "automatic at restart" when a login item is
    /// registered and the system has just booted into a session.
    private var launchedAutomatically: Bool {
        ProcessInfo.processInfo.systemUptime < 180
            && SMAppService.mainApp.status == .enabled
    }

    private func shouldShowWindowAtLaunch() -> Bool {
        let defaults = UserDefaults.standard
        if launchedAutomatically {
            let staysHidden = defaults.bool(forKey: "hideWindowAtLoginLaunch")
            return !staysHidden
        }
        return defaults.object(forKey: "showWindowOnLaunch") == nil
            ? true
            : defaults.bool(forKey: "showWindowOnLaunch")
    }

    private func refreshTimer() {
        timer?.invalidate()
        let interval = max(1, UserDefaults.standard.object(forKey: "refreshMinutes") as? Double ?? 2) * 60
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in await self?.pull() }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        refreshTask?.cancel()
        timer?.invalidate()
        NotificationCenter.default.removeObserver(self)
    }

    @MainActor
    func pull() async {
        await AppState.shared.refresh()
        status.refreshImage()
    }

    /// The main program window. Closing it never ends the agent: the window is
    /// cached, hidden, and re-openable from the status bar at any time.
    func showMainWindow() {
        if mainWindow == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 620, height: 720),
                styleMask: [.titled, .miniaturizable, .closable, .resizable],
                backing: .buffered, defer: false)
            window.title = "AI CreditPulse"
            window.contentView = NSHostingView(rootView: MainWindowView())
            window.center()
            // This app has no window restoration: nothing should resurrect the
            // window (or a stale cached one) across relaunches.
            window.isRestorable = false
            // Keep the instance alive when the user closes the window — the
            // agent must stay in the menu bar (memory stays owned by us).
            window.isReleasedWhenClosed = false
            mainWindow = window
        }
        mainWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
