import Foundation

/// A provider adapter reads one provider's balance/usage and returns a normalized
/// ProviderResult. All adapters share the EnvStore for credentials, the keychain /
/// auth-file fallbacks in ModelStore, and ProviderHTTP's cache + safe errors.
public protocol ProviderAdapter: Sendable {
    var id: String { get }
    var label: String { get }
    var kind: ProviderResult.Kind { get }
    var unit: String { get }
    /// The .env key names this provider uses, for the Settings UI field labels.
    var credentialHints: [String] { get }
    func fetch() async -> ProviderResult
}

/// Registry + combined refresh. Ports the plugin's ADAPTERS/ORDER table and the
/// /summary route: providers fetch concurrently, and a failed adapter keeps its
/// own identity in the summary rather than crashing the whole pull.
public enum ProviderRegistry {
    /// Builtins first, then the user's custom URL-key providers. Computed so a
    /// freshly saved custom provider appears WITHOUT an app restart;
    /// `snapshot()` re-reads this on every pull.
    public static var adapters: [ProviderAdapter] {
        builtin + CustomProviderStore.load().map(CustomProviderAdapter.init)
    }

    public static let builtin: [ProviderAdapter] = [
        NousAdapter(), CodexAdapter(), ClaudeAdapter(), ZAIAdapter(),
        OpenCodeAdapter(), CommandCodeAdapter(), DeepSeekAdapter(),
        OpenRouterAdapter(), ILMUAdapter(),
    ]

    public static func adapter(_ id: String) -> (any ProviderAdapter)? {
        adapters.first { $0.id == id }
    }

    public struct Snapshot: Sendable, Equatable {
        public var providers: [ProviderResult]
        public var combinedBalanceUSD: Double
        public var combinedBalanceCredits: Double
        public var ts: Date

        /// Red when any provider hit its limit, depleted a paid balance, or
        /// failed; amber at >= 60% of any published window (the card's thresholds).
        public var status: MenubarStatus {
            MenubarStatus.worst(of: providers)
        }
    }

    public enum MenubarStatus { case green, amber, red, grey

        public var color: String { switch self { case .green: "green"; case .amber: "amber"; case .red: "red"; case .grey: "grey" } }

        /// The worst status across the given rows. Factored out of the snapshot so
        /// the app can run it over only the rows the user chose to show — a
        /// hidden provider must not colour the menu bar it is hidden from.
        /// An unconfigured row (no key yet / stale credential to re-paste) is an
        /// idle state, not an alarm: it lifts the badge to grey, never red.
        public static func worst(of rows: [ProviderResult]) -> MenubarStatus {
            var worst = MenubarStatus.green
            for p in rows {
                if !p.ok {
                    worst = worst.promote(p.isUnconfigured ? .grey : .red)
                    continue
                }
                if p.limitReached { worst = worst.promote(.red); continue }
                if p.kind == .balance, let v = p.value, v <= 0, !p.unlimited,
                   !PlanFlags.isFreeOrTrial(p.plan) {
                    worst = worst.promote(.red)
                }
                let windows = [p.effectivePrimaryUsagePercent,
                               p.effectiveWeeklyUsagePercent,
                               p.effectiveMonthlyUsagePercent].compactMap(\.self)
                let maxUsed = windows.max()
                if maxUsed != nil, maxUsed! >= 90 { worst = worst.promote(.red) }
                else if maxUsed != nil, maxUsed! >= 60 { worst = worst.promote(.amber) }
            }
            return worst
        }

        private static let rank: [MenubarStatus: Int] = [.green: 0, .grey: 1, .amber: 2, .red: 3]

        /// Monotonic upgrade — grey (idle) can never drown out a real alarm.
        func promote(_ other: MenubarStatus) -> MenubarStatus {
            Self.rank[other]! > Self.rank[self]! ? other : self
        }
    }

    public enum PlanFlags {
        /// A plan explicitly free/trial/none is not a fault when its credit is 0;
        /// a missing plan counts as paid (ports the card's depleted-balance rule).
        public static func isFreeOrTrial(_ plan: String?) -> Bool {
            guard let p = plan?.lowercased() else { return false }
            return p.contains("free") || p.contains("trial") || p == "none"
        }
    }

    /// Clears every adapter's HTTP cache (public wrapper for the refresh-now path).
    public static func clearCaches() { ProviderHTTP.clearCache() }

    /// One full pull: concurrent fetches, combined headline by unit (USD vs credits),
    /// exactly like the /summary route. MYR goes into neither bucket (detail-only).
    public static func snapshot() async -> Snapshot {
        let results = await withTaskGroup(of: (Int, ProviderResult).self) { group in
            for (index, adapter) in adapters.enumerated() {
                group.addTask { (index, await adapter.fetch()) }
            }
            var indexed: [Int: ProviderResult] = [:]
            for await (index, result) in group { indexed[index] = result }
            return indexed.sorted { $0.key < $1.key }.map(\.value)
        }
        let usd = results
            .filter { $0.kind == .balance && $0.ok && $0.value != nil && $0.unit.uppercased() == "USD" }
            .reduce(0.0) { $0 + ($1.value ?? 0) }
        let credits = results
            .filter { $0.kind == .balance && $0.ok && $0.value != nil && $0.unit.uppercased() == "CREDITS" }
            .reduce(0.0) { $0 + ($1.value ?? 0) }
        return Snapshot(
            providers: results,
            combinedBalanceUSD: (usd * 100).rounded() / 100,
            combinedBalanceCredits: (credits * 100).rounded() / 100,
            ts: Date())
    }
}
