import Foundation

/// Normalized provider result — the Swift port of the Hermes plugin's `_result()`
/// contract (backend/plugin_api.py). One shape for every provider, so the menu bar
/// dropdown never needs per-provider special cases.
///
/// Window vocabulary: primary = shortest rolling window (5h), weekly, monthly.
/// A provider leaves a window nil when it has no such concept.
public struct ProviderResult: Sendable, Equatable {
    public let id: String
    public let label: String
    /// "balance" = monetary/credit headline (USD, credits, MYR).
    /// "usage"  = window-percent headline.
    public let kind: Kind
    /// Headline number: remaining balance for `balance`, percent used for `usage`.
    public let value: Double?
    public let unit: String
    public let detail: String
    public let ok: Bool
    /// Safe error vocabulary only — never provider response text.
    public let error: String?
    public let ts: Date

    public var plan: String?
    public var renewalAt: Date?
    public var nextResetAt: Date?
    public var weeklyResetAt: Date?
    public var monthlyResetAt: Date?

    public var primaryUsagePercent: Double?
    public var weeklyUsagePercent: Double?
    public var monthlyUsagePercent: Double?

    /// What the window percentages MEAN. Providers publish wildly different
    /// directions (Anthropic's utilization = % used; several relays report
    /// % remaining), and an unlabeled number reads backwards half the time.
    /// `.used`  → the bar fills as the quota burns, "n% used".
    /// `.left`  → the bar shows what REMAINS filled; the burned share is off.
    public enum UsageSemantics: String, Sendable, Codable { case used, left }
    public var usageSemantics: UsageSemantics = .used

    /// The numeric percent the BAR should fill, after the semantic is applied:
    /// "left" providers invert, so a row nearly out of credit paints red.
    public func barPercent(_ pct: Double) -> Double {
        usageSemantics == .left ? 100.0 - pct : pct
    }

    /// Unambiguous window caption, e.g. "43% used" / "43% left".
    public func windowCaption(_ pct: Double) -> String {
        String(format: "%.0f%% %@", pct,
               usageSemantics == .left ? "left" : "used")
    }

    /// Percent measures of CONSUMPTION (what every threshold consumer wants).
    /// A `.left` row is converted so status math never inverts by accident.
    public var effectivePrimaryUsagePercent: Double? {
        primaryUsagePercent.map(barPercent)
    }
    public var effectiveWeeklyUsagePercent: Double? {
        weeklyUsagePercent.map(barPercent)
    }
    public var effectiveMonthlyUsagePercent: Double? {
        monthlyUsagePercent.map(barPercent)
    }

    public var limitReached: Bool
    /// Provider answered and reports no ceiling at all (OpenRouter with no
    /// per-key limit). Distinct from a failure.
    public var unlimited: Bool

    public enum Kind: String, Sendable { case balance, usage }

    /// True when the row is missing a usable credential rather than reporting a
    /// live failure. Vocabulary is authored by the adapters, never a provider.
    public var isUnconfigured: Bool {
        switch error {
        case "no API key", "no OAuth token", "no access token",
             "no apiKey in auth.json", "no ~/.codex/auth.json",
             "no ~/.commandcode/auth.json", "no console session cookie",
             "console session expired - re-paste the cookie",
             "token expired — run `claude` once to refresh":
            return true
        default: return false
        }
    }

    public static func unavailable(
        _ id: String, _ label: String, kind: Kind, unit: String,
        error: String? = nil, plan: String? = nil
    ) -> ProviderResult {
        // Only authored vocabulary may reach the UI, no matter the source.
        return ProviderResult(
            id: id, label: label, kind: kind, value: nil, unit: unit, detail: "",
            ok: false, error: error.map { ProviderHTTP.sanitized($0) }, ts: Date(), plan: plan,
            renewalAt: nil, nextResetAt: nil, weeklyResetAt: nil, monthlyResetAt: nil,
            primaryUsagePercent: nil, weeklyUsagePercent: nil, monthlyUsagePercent: nil,
            limitReached: false, unlimited: false)
    }

    /// Public memberwise equivalent — full-control construction (tests, the
    /// custom-provider adapter style). Prefer `unavailable` for error rows so
    /// the safe-vocabulary voucher is applied centrally.
    public init(
        id: String, label: String, kind: Kind, value: Double?, unit: String,
        detail: String, ok: Bool, error: String?, ts: Date, plan: String?,
        renewalAt: Date?, nextResetAt: Date?, weeklyResetAt: Date?, monthlyResetAt: Date?,
        primaryUsagePercent: Double?, weeklyUsagePercent: Double?, monthlyUsagePercent: Double?,
        limitReached: Bool, unlimited: Bool, usageSemantics: UsageSemantics = .used
    ) {
        self.id = id
        self.label = label
        self.kind = kind
        self.value = value
        self.unit = unit
        self.detail = detail
        self.ok = ok
        self.error = error
        self.ts = ts
        self.plan = plan
        self.renewalAt = renewalAt
        self.nextResetAt = nextResetAt
        self.weeklyResetAt = weeklyResetAt
        self.monthlyResetAt = monthlyResetAt
        self.primaryUsagePercent = primaryUsagePercent
        self.weeklyUsagePercent = weeklyUsagePercent
        self.monthlyUsagePercent = monthlyUsagePercent
        self.usageSemantics = usageSemantics
        self.limitReached = limitReached
        self.unlimited = unlimited
    }
}

// MARK: - Field normalization helpers (ports of _number / _text / _plan / _iso_date)

enum Norm {
    /// Finite number from any JSON value (ports `_number`).
    static func number(_ value: Any?) -> Double? {
        switch value {
        case let n as NSNumber:
            // CFBooleanRef bridges as NSNumber; a bool is never a quantity.
            if CFGetTypeID(n) == CFBooleanGetTypeID() { return nil }
            return n.doubleValue.isFinite ? n.doubleValue : nil
        case let s as String:
            guard !s.isEmpty, let d = Double(s), d.isFinite else { return nil }
            return d
        default:
            return nil
        }
    }

    /// Compact display number for detail strings: "?" when absent, no float noise (ports `_text`).
    static func text(_ value: Any?) -> String {
        guard let n = number(value) else { return "?" }
        var s = String(format: "%.2f", n)
        while s.hasSuffix("0") { s.removeLast() }
        if s.hasSuffix(".") { s.removeLast() }
        return s.isEmpty ? "0" : s
    }

    /// Plan name from a string or {"name": ...} dict; never stringify other objects (ports `_plan`).
    static func plan(_ value: Any?) -> String? {
        var v = value
        if let d = value as? [String: Any] { v = d["name"] }
        guard let s = v as? String, !s.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        return String(s.trimmingCharacters(in: .whitespaces).prefix(100))
    }

    /// Parse an ISO date / unix seconds into a UTC instant (ports `_iso_date`'s parse half).
    static func date(_ value: Any?) -> Date? {
        if value is Bool { return nil }
        if let d = value as? Date { return d }
        guard let n = number(value) else {
            guard let s = value as? String, !s.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
            let raw = s.trimmingCharacters(in: .whitespaces)
            // The provider contract normalizes 10-char values as date-only midnight UTC.
            if raw.count == 10, let d = Formatter.dayOnly.date(from: raw) { return d }
            guard let d = Formatter.iso.date(from: raw) ?? Formatter.fallback.date(from: raw) else { return nil }
            return d
        }
        // Abs(n) >= 1e11 means milliseconds.
        let seconds = abs(n) >= 1e11 ? n / 1000 : n
        return Date(timeIntervalSince1970: seconds)
    }

    /// True when an ISO instant is still ahead of now (ports `_future`).
    static func isFuture(_ value: Any?) -> Bool {
        guard let d = date(value) else { return false }
        return d > Date()
    }

    /// Reset instant from a window dict (ports `_reset`).
    static func reset(_ window: [String: Any]?, observedAt: Date? = nil) -> Date? {
        guard let window else { return nil }
        for field in ["resets_at", "reset_at", "resetsAt", "resetAt"] {
            guard window[field] != nil else { continue }
            // Some APIs use 0 to mean no reset is scheduled.
            if let n = number(window[field]), n <= 0 { continue }
            if let d = date(window[field]) { return d }
        }
        guard let seconds = number(window["reset_after_seconds"]), seconds > 0 else { return nil }
        let base = observedAt ?? Date()
        return base.addingTimeInterval(seconds)
    }

    enum Formatter {
        static let iso: ISO8601DateFormatter = {
            let f = ISO8601DateFormatter()
            f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            return f
        }()
        static let fallback: ISO8601DateFormatter = {
            let f = ISO8601DateFormatter()
            return f
        }()
        static let dayOnly: DateFormatter = {
            let f = DateFormatter()
            f.dateFormat = "yyyy-MM-dd"
            f.timeZone = TimeZone(identifier: "UTC")
            f.locale = Locale(identifier: "en_US_POSIX")
            return f
        }()
    }
}
