import Foundation
import SwiftUI
import AICreditPulseCore

/// User preferences in UserDefaults — ports the plugin's `visibleProviderIds` and
/// `refreshMinutes` storage rules: stored arrays are filtered to known IDs,
/// malformed settings fall back to defaults.
@MainActor
final class AppState: ObservableObject {
    static let shared = AppState()

    static let refreshChoices: [Double] = [2, 5, 10]

    @Published var snapshot: ProviderRegistry.Snapshot?
    @Published var isRefreshing = false

    private var timer: Timer?

    @AppStorage("refreshMinutes") private var storedRefreshMinutes: Double = 2
    @AppStorage("visibleProviderIds") private var storedVisible: String = ""
    @AppStorage("launchAtLogin") var launchAtLogin = false

    var refreshMinutes: Double {
        get {
            Self.refreshChoices.contains(storedRefreshMinutes) ? storedRefreshMinutes : 2
        }
        set {
            guard Self.refreshChoices.contains(newValue) else { return }
            storedRefreshMinutes = newValue
            restartTimer()
        }
    }

    /// Visible provider IDs, filtered to known IDs against the registry order.
    var visibleProviderIDs: [String] {
        get {
            let stored = storedVisible.split(separator: ",").map(String.init)
            guard !storedVisible.isEmpty else { return ProviderRegistry.adapters.map(\.id) }
            let known = ProviderRegistry.adapters.map(\.id)
            return known.filter { stored.contains($0) }
        }
        set {
            storedVisible = newValue.joined(separator: ",")
            objectWillChange.send()
        }
    }

    func isProviderVisible(_ id: String) -> Bool {
        visibleProviderIDs.contains(id)
    }

    /// Show/hide selector for one provider: hidden rows leave the dropdown, the
    /// combined headline and the work-status badge they could colour.
    func setProviderVisible(_ id: String, _ visible: Bool) {
        var ids = visibleProviderIDs
        if visible {
            if !ids.contains(id) { ids.append(id) }
        } else if let index = ids.firstIndex(of: id) {
            ids.remove(at: index)
        }
        visibleProviderIDs = ids
    }

    /// Combined headline over the visible rows only — the same USD/credits
    /// split the /summary route applies (MYR stays detail-only).
    var combinedUSD: Double {
        let usd = visibleProviders
            .filter { $0.kind == .balance && $0.ok && $0.value != nil && $0.unit.uppercased() == "USD" }
            .reduce(0.0) { $0 + ($1.value ?? 0) }
        return (usd * 100).rounded() / 100
    }

    var combinedCredits: Double {
        let credits = visibleProviders
            .filter { $0.kind == .balance && $0.ok && $0.value != nil && $0.unit.uppercased() == "CREDITS" }
            .reduce(0.0) { $0 + ($1.value ?? 0) }
        return (credits * 100).rounded() / 100
    }

    /// Work-status badge over the visible rows only: a hidden provider cannot
    /// keep the menu bar red or amber about itself.
    var visibleStatus: ProviderRegistry.MenubarStatus {
        ProviderRegistry.MenubarStatus.worst(of: visibleProviders)
    }

    var visibleProviders: [ProviderResult] {
        let visible = Set(visibleProviderIDs)
        return (snapshot?.providers ?? []).filter { visible.contains($0.id) }
    }

    private init() {
        restartTimer()
    }

    func restartTimer() {
        timer?.invalidate()
        let interval = refreshMinutes * 60
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in await self?.refresh() }
        }
    }

    @MainActor
    func refresh(force: Bool = false) async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        if force { ProviderRegistry.clearCaches() }
        snapshot = await ProviderRegistry.snapshot()
    }
}
