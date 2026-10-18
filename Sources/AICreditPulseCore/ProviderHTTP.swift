import Foundation

/// Shared HTTP + caching layer — the Swift port of the plugin's `_get`, `_post`,
/// `_safe_error`, `_safe_reason` and `_cached`.
///
/// Error vocabulary is fixed: only reasons this module authors may reach the UI,
/// so a provider payload can never inject text through us.
enum HTTPError: Error {
    case http(Int)
    case timedOut
    case unreachable
    case transport(String)

    var safeText: String {
        switch self {
        case .http(let code): "provider request failed (HTTP \(code))"
        case .timedOut: "provider request timed out"
        case .unreachable: "provider unreachable"
        case .transport: "provider data unavailable"
        }
    }
}

/// Cache entry: (storedAt, value). Ports `_cache[key] = (now, val)`.
private final class CacheBox: @unchecked Sendable {
    private var entries: [String: (Date, Any)] = [:]
    private let lock = NSLock()

    func get(_ key: String, ttl: TimeInterval) -> (value: Any, age: TimeInterval)? {
        lock.lock(); defer { lock.unlock() }
        guard let (at, value) = entries[key] else { return nil }
        let age = Date().timeIntervalSince(at)
        return age < ttl ? (value, age) : nil
    }

    /// Stores a value and returns its storage instant — usage windows derived from
    /// `reset_after_seconds` are dated by the fetch, not by a later cache read.
    func set(_ key: String, _ value: Any) -> Date {
        let now = Date()
        lock.lock(); defer { lock.unlock() }
        entries[key] = (now, value)
        return now
    }

    func storedAt(_ key: String) -> Date? {
        lock.lock(); defer { lock.unlock() }
        return entries[key]?.0
    }

    func clear() {
        lock.lock(); defer { lock.unlock() }
        entries.removeAll()
    }
}

enum ProviderHTTP {
    static let defaultTTL: TimeInterval = 120  // seconds (CACHE_TTL)
    static let userAgent = "aicreditpulse/1.0"

    /// One cache for every adapter; entries are keyed per provider/route.
    private static let cache = CacheBox()

    public static func clearCache() { cache.clear() }

    static func get(_ url: URL, headers: [String: String] = [:], timeout: TimeInterval = 10) async throws -> Any {
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = "GET"
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        for (k, v) in headers { request.setValue(v, forHTTPHeaderField: k) }
        return try await send(request)
    }

    static func post(_ url: URL, headers: [String: String] = [:], body: [String: Any], timeout: TimeInterval = 10) async throws -> Any {
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        for (k, v) in headers { request.setValue(v, forHTTPHeaderField: k) }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return try await send(request)
    }

    /// POST whose HTTP-error status is returned, not thrown: the Z.ai PAYG probe
    /// classifies a documented error envelope (the depleted-wallet code), so the
    /// adapter must see the status and the parsed body together. Transport
    /// failures still throw.
    static func postRaw(_ url: URL, headers: [String: String] = [:], body: [String: Any], timeout: TimeInterval = 10) async throws -> (status: Int, json: Any?) {
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        for (k, v) in headers { request.setValue(v, forHTTPHeaderField: k) }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let json = try? JSONSerialization.jsonObject(with: data)
        return (status, json)
    }

    private static func send(_ request: URLRequest) async throws -> Any {
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw HTTPError.http(http.statusCode)
        }
        return try JSONSerialization.jsonObject(with: data)
    }

    /// Every reason this module is allowed to publish. Anything else — a provider
    /// payload that happens to carry its own `error` key, for instance — is
    /// replaced by the generic message, so foreign text can never reach the
    /// client through us. Port of the plugin's `_safe_reason`.
    private static let authoredReasons: Set<String> = [
        "provider request timed out",
        "provider unreachable",
        "provider data unavailable",
        "no OAuth token",
        "no access token",
        "no API key",
        "no apiKey in auth.json",
        "no ~/.codex/auth.json",
        "no ~/.commandcode/auth.json",
        "token expired — run `claude` once to refresh",
        "no console session cookie",
        "console session expired - re-paste the cookie",
    ]

    /// Passes through only text this module authored; anything else falls back.
    public static func sanitized(_ text: String, fallback: String = "provider data unavailable") -> String {
        if authoredReasons.contains(text) { return text }
        // "provider request failed (HTTP \d{3})"
        if text.hasPrefix("provider request failed (HTTP"), text.hasSuffix(")") {
            let digits = text.dropFirst("provider request failed (HTTP".count)
                .dropLast(1).trimmingCharacters(in: .whitespaces)
            if digits.count == 3, digits.allSatisfy(\.isNumber) { return text }
        }
        return fallback
    }

    /// Maps a thrown error into the safe vocabulary (ports `_safe_error`).
    static func safe(_ error: Error) -> String {
        switch error {
        case let e as HTTPError: return e.safeText
        case is URLError:
            if (error as? URLError)?.code == .timedOut { return HTTPError.timedOut.safeText }
            return HTTPError.unreachable.safeText
        default: return HTTPError.transport("").safeText
        }
    }

    /// Fresh-past-TTL read + retry on miss (ports `_cached`). `fetch` may throw;
    /// a failure is itself cached so a dead provider doesn't hammer its API.
    static func cached<T>(_ key: String, ttl: TimeInterval = defaultTTL, fetch: @escaping @Sendable () async throws -> T) async -> Result<T, ProviderFailure> {
        if let hit = cache.get(key, ttl: ttl) { return .success(hit.value as! T) }
        do {
            let value = try await fetch()
            cache.set(key, value)
            return .success(value)
        } catch {
            let reason = safe(error)
            cache.set(key, reason)
            return .failure(ProviderFailure(reason: reason))
        }
    }

    /// Whether the last stored entry for `key` was a failure value (a String reason).
    static func lastWasFailure(_ key: String) -> Bool {
        cache.get(key, ttl: .infinity) != nil
    }

    /// The stored instant of `key` — the `observedAt` anchor for derived windows.
    static func observedAt(_ key: String) -> Date? { cache.storedAt(key) }
}

/// A cached-fetch failure bounded to the safe vocabulary (Result's Failure must be an Error).
struct ProviderFailure: Error {
    let reason: String
}

/// Result helpers mirroring the Python adapters' `{"ok": ..., "error": ...}` bundles.
/// Each fetch inside a bundled sample fails independently, so a decoration route
/// can never blank the headline (the plugin's one-instant-many-routes pattern).
extension Result where Success == [String: Any], Failure == ProviderFailure {
    var dict: [String: Any] { (try? get()) ?? [:] }
    var ok: Bool {
        switch self {
        case .success: return true
        case .failure: return false
        }
    }
}
