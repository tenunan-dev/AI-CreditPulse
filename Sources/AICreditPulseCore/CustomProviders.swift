import Foundation

/// A USER-DEFINED provider: any OpenAI-style (Authorization: Bearer) or
/// Anthropic-style (x-api-key + anthropic-version) HTTP endpoint that exposes
/// balance/usage as plain JSON. The user points us at a URL, gives us the key,
/// and tells us WHERE in the response the number lives (dot paths like
/// `data.total_credits` or `rate_limit.primary_window.remaining_percent`).
///
/// Two reading modes:
///  - amount mode: `remainingPath` is a remaining balance (e.g. 7.25 USD);
///  - percent mode: `remainingPath` is a % remaining — rendered with `.left`
///    semantics so the bars and thresholds stay truthful.
public struct CustomProviderConfig: Codable, Sendable, Equatable, Identifiable {
    public var id: String          // stable slug, e.g. "relay-moonshot"
    public var name: String
    /// "openai" | "anthropic"
    public var authStyle: String
    public var url: String
    public var remainingPath: String
    public var limitPath: String?
    /// `.left`: the endpoint reports a PERCENT remaining, plain: an amount.
    public var reportsPercentLeft: Bool
    public var unit: String        // USD default; ILMU-style units allowed

    public init(id: String, name: String, authStyle: String, url: String,
                remainingPath: String, limitPath: String? = nil,
                reportsPercentLeft: Bool = false, unit: String = "USD") {
        self.id = id
        self.name = name
        self.authStyle = authStyle
        self.url = url
        self.remainingPath = remainingPath
        self.limitPath = limitPath
        self.reportsPercentLeft = reportsPercentLeft
        self.unit = unit
    }

    /// The .env slot for this provider's key (written via EnvStore so the
    /// normal save/verify flow applies).
    public var envKey: String {
        "CUSTOM_" + id.uppercased().replacingOccurrences(of: "-", with: "_") + "_API_KEY"
    }

    /// Keeps ids filesystem/URL friendly and unique-looking.
    public static func slug(_ name: String) -> String {
        let cleaned = name.lowercased()
            .replacingOccurrences(of: "[^a-z0-9]+", with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return cleaned.isEmpty ? "custom" : String(cleaned.prefix(24))
    }
}

/// Persistence for custom providers — a small JSON file next to .env, so the
/// user can hand-edit or back it up with their keys. 0600 like the key file.
public enum CustomProviderStore {
    public static var url: URL {
        EnvStore.defaultURL.deletingLastPathComponent()
            .appendingPathComponent("custom_providers.json")
    }

    public static func load() -> [CustomProviderConfig] {
        guard let data = FileManager.default.contents(atPath: url.path) else { return [] }
        return (try? JSONDecoder().decode([CustomProviderConfig].self, from: data)) ?? []
    }

    public static func save(_ configs: [CustomProviderConfig]) throws {
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(configs).write(to: url)
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}

/// Resolve a dot path ("data.total_credits", "usage[0].limit", plain "balance")
/// into a JSON subtree. Numeric segments index arrays.
public enum JSONPath {
    public static func resolve(_ path: String, in root: Any?) -> Any? {
        var cursor = root
        for rawSegment in path.split(separator: ".").map(String.init) where !rawSegment.isEmpty {
            // Split "segments[2]" style tails into their index part.
            if let open = rawSegment.firstIndex(of: "[") {
                let head = String(rawSegment[rawSegment.startIndex..<open])
                if !head.isEmpty {
                    cursor = child(head, of: cursor)
                    if cursor == nil { return nil }
                }
                for indexPart in rawSegment[open...].replacingOccurrences(of: "]", with: "")
                    .split(separator: "[").map(String.init) {
                    cursor = child(indexPart, of: cursor)
                    if cursor == nil { return nil }
                }
            } else {
                cursor = child(rawSegment, of: cursor)
                if cursor == nil { return nil }
            }
        }
        return cursor
    }

    private static func child(_ key: String, of node: Any?) -> Any? {
        if let dict = node as? [String: Any], let value = dict[key] { return value }
        if let array = node as? [Any], let index = Int(key), array.indices.contains(index) { return array[index] }
        return nil
    }
}

/// The runtime adapter for a user-defined provider. It intentionally shares
/// ProviderHTTP's cache/safe-error plumbing so it behaves like a builtin.
public struct CustomProviderAdapter: ProviderAdapter {
    public let config: CustomProviderConfig

    public init(_ config: CustomProviderConfig) { self.config = config }

    public var id: String { config.id }
    public var label: String { config.name }
    public var kind: ProviderResult.Kind {
        config.reportsPercentLeft ? .usage : .balance
    }
    public var unit: String { config.reportsPercentLeft ? "%" : config.unit }
    public var credentialHints: [String] { [config.envKey] }

    public func fetch() async -> ProviderResult {
        guard let key = EnvStore.shared.key(config.envKey),
              !key.trimmingCharacters(in: .whitespaces).isEmpty else {
            return .unavailable(id, label, kind: kind, unit: unit, error: "no API key")
        }
        guard let target = URL(string: config.url), target.scheme == "https" || target.scheme == "http" else {
            return .unavailable(id, label, kind: kind, unit: unit, error: "bad URL in custom provider settings")
        }
        var headers: [String: String]
        switch config.authStyle {
        case "anthropic":
            headers = ["x-api-key": key, "anthropic-version": "2023-06-01"]
        default:
            headers = ["Authorization": "Bearer \(key)"]
        }

        let cacheKey = "custom-\(id)"
        let outcome = await ProviderHTTP.cached(cacheKey) {
            try await ProviderHTTP.get(target, headers: headers)
        }
        guard case .success(let data) = outcome else {
            return .unavailable(id, label, kind: kind, unit: unit, error: "provider data unavailable")
        }
        guard let remaining = Norm.number(JSONPath.resolve(config.remainingPath, in: data)) else {
            return .unavailable(id, label, kind: kind, unit: unit, error: "JSON path found no number")
        }

        // Percent mode: remaining % — wire `.left` semantics so thresholds,
        // bars and captions all read the right way round.
        if config.reportsPercentLeft {
            let pct = max(0, min(100, remaining))
            return ProviderResult(
                id: id, label: label, kind: .usage, value: pct, unit: "%",
                detail: config.limitPath.flatMap {
                    Norm.number(JSONPath.resolve($0, in: data)).map { String(format: "limit %.1f%%", $0) }
                } ?? "",
                ok: true, error: nil, ts: Date(),
                plan: nil, renewalAt: nil, nextResetAt: nil, weeklyResetAt: nil, monthlyResetAt: nil,
                primaryUsagePercent: pct, weeklyUsagePercent: nil, monthlyUsagePercent: nil,
                limitReached: pct <= 0, unlimited: false,
                usageSemantics: .left)
        }

        // Amount mode: remaining balance, optional published limit for context.
        let limit = config.limitPath.flatMap { Norm.number(JSONPath.resolve($0, in: data)) }
        var detail = limit.map { String(format: "limit %@", Norm.text($0)) } ?? ""
        if limit == nil, config.limitPath != nil { detail = "limit missing" }
        return ProviderResult(
            id: id, label: label, kind: .balance, value: remaining, unit: unit,
            detail: detail,
            ok: true, error: nil, ts: Date(),
            plan: nil, renewalAt: nil, nextResetAt: nil, weeklyResetAt: nil, monthlyResetAt: nil,
            primaryUsagePercent: nil, weeklyUsagePercent: nil, monthlyUsagePercent: nil,
            limitReached: remaining <= 0, unlimited: false)
    }
}
