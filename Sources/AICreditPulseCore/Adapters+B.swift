import Foundation

/// DeepSeek prepaid wallet via GET https://api.deepseek.com/user/balance.
/// Amounts arrive as strings ("14.87") — Norm.number parses them. Verified live
/// in the Hermes plugin (Sep 2026).
public struct DeepSeekAdapter: ProviderAdapter {
    public init() {}
    public let id: String = "deepseek"
    public let label: String = "DeepSeek"
    public let kind = ProviderResult.Kind.balance
    public let unit: String = "USD"
    public let credentialHints: [String] = ["DEEPSEEK_API_KEY"]

    public func fetch() async -> ProviderResult {
        guard let key = EnvStore.shared.key("DEEPSEEK_API_KEY") else {
            return .unavailable(id, label, kind: kind, unit: unit, error: "no API key")
        }
        let outcome = await ProviderHTTP.cached("deepseek") {
            try await ProviderHTTP.get(URL(string: "https://api.deepseek.com/user/balance")!,
                                       headers: ["Authorization": "Bearer \(key)"]) as! [String: Any]
        }
        guard case .success(let raw) = outcome,
              let payload = raw as? [String: Any],
              let infos = payload["balance_infos"] as? [[String: Any]],
              let bal = infos.first else {
            return .unavailable(id, label, kind: kind, unit: unit, error: "provider data unavailable")
        }
        let currency = (bal["currency"] as? String).uppercasedSafe ?? "USD"
        return ProviderResult(
            id: id, label: label, kind: kind,
            value: Norm.number(bal["total_balance"]), unit: (currency == "USD" || currency == "CNY") ? currency : "USD",
            detail: "avail \(Norm.text(bal["granted_balance"])), pending \(Norm.text(bal["topped_up_balance"]))",
            ok: true, error: nil, ts: Date(),
            plan: nil, renewalAt: nil, nextResetAt: nil, weeklyResetAt: nil, monthlyResetAt: nil,
            primaryUsagePercent: nil, weeklyUsagePercent: nil, monthlyUsagePercent: nil,
            limitReached: false, unlimited: false)
    }
}

private extension Optional where Wrapped == String {
    var uppercasedSafe: String? { self?.uppercased() }
}

/// OpenRouter wallet + per-key limits via GET /api/v1/credits and /api/v1/key,
/// sampled under ONE cache entry so a fresh wallet never pairs with a stale key
/// read (the plugin's openrouter() behavior). The wallet is the headline; the
/// key's optional spending ceiling is the limit_reached flag only.
public struct OpenRouterAdapter: ProviderAdapter {
    public init() {}
    public let id: String = "openrouter"
    public let label: String = "OpenRouter"
    public let kind = ProviderResult.Kind.balance
    public let unit: String = "USD"
    public let credentialHints: [String] = ["OPENROUTER_API_KEY"]

    public func fetch() async -> ProviderResult {
        guard let key = EnvStore.shared.key("OPENROUTER_API_KEY") else {
            return .unavailable(id, label, kind: kind, unit: unit, error: "no API key")
        }
        let headers = ["Authorization": "Bearer \(key)"]
        let outcome = await ProviderHTTP.cached("openrouter") {
            var results: [String: Result<Any, ProviderFailure>] = [:]
            for (name, path) in [("credits", "https://openrouter.ai/api/v1/credits"),
                                 ("key", "https://openrouter.ai/api/v1/key")] {
                // Each endpoint fails independently — a 403 on /credits (management
                // key required) must not cost the /key row.
                do {
                    let data = try await ProviderHTTP.get(URL(string: path)!, headers: headers)
                    results[name] = .success(data)
                } catch {
                    results[name] = .failure(ProviderFailure(reason: ProviderHTTP.safe(error)))
                }
            }
            return results
        }
        guard case .success(let rawBundle) = outcome, let bundle = rawBundle as? [String: Result<Any, ProviderFailure>] else {
            return .unavailable(id, label, kind: kind, unit: unit, error: "provider data unavailable")
        }
        let credits = unwrap(bundle["credits"])
        let keyResult = unwrap(bundle["key"])
        let creditData = ((credits["data"] as? [String: Any])?["data"] as? [String: Any]) ?? [:]
        let keyData = (keyResult["data"] as? [String: Any])?["data"] as? [String: Any] ?? [:]
        let totalCredits = Norm.number(creditData["total_credits"])
        let totalUsage = Norm.number(creditData["total_usage"])
        let hasCredits = (credits["ok"] as? Bool) == true && totalCredits != nil && totalUsage != nil
        let hasKey = (keyResult["ok"] as? Bool) == true && !keyData.isEmpty

        if !hasCredits && !hasKey {
            let reason = (credits["ok"] as? Bool) == false
                ? (credits["error"] as? String) : (keyResult["error"] as? String)
            return .unavailable(id, label, kind: kind, unit: unit,
                                error: reason ?? "provider data unavailable")
        }

        var detail = ""
        if hasCredits {
            detail = "granted $\(String(format: "%.2f", totalCredits!)) / used $\(String(format: "%.2f", totalUsage!))"
        } else {
            let keyUsed = Norm.number(keyData["usage"])
            detail = "credit unavailable" + (keyUsed.map { " - key spend $\($0)" } ?? "")
        }
        var windows: [String] = []
        for (label, field) in [("24h", "usage_daily"), ("7d", "usage_weekly"), ("30d", "usage_monthly")] {
            if let v = Norm.number(keyData[field]) { windows.append("\(label) $\(String(format: "%.2f", v))") }
        }
        if !windows.isEmpty { detail += " · key " + windows.joined(separator: " · ") }

        var keyRemaining = Norm.number(keyData["limit_remaining"])
        let keyLimit = Norm.number(keyData["limit"])
        if let limit = keyLimit {
            if keyRemaining == nil {
                let keyUsed = Norm.number(keyData["usage"])
                keyRemaining = keyUsed.map { limit - $0 }
            }
            let left = keyRemaining.map { String(format: "%.2f", $0) } ?? "?"
            detail += " · key limit $\(String(format: "%.2f", limit)), $\(left) left"
        }

        let wallet = hasCredits ? totalCredits! - totalUsage! : nil
        let unlimited = hasCredits && hasKey && keyData["limit"] == nil
        let limitReached = wallet.map { $0 > 0 } == true
            && keyRemaining.map { $0 <= 0 } == true
        return ProviderResult(
            id: id, label: label, kind: kind, value: wallet, unit: unit, detail: detail,
            ok: true, error: nil, ts: Date(),
            plan: nil, renewalAt: nil, nextResetAt: nil, weeklyResetAt: nil, monthlyResetAt: nil,
            primaryUsagePercent: nil, weeklyUsagePercent: nil, monthlyUsagePercent: nil,
            limitReached: limitReached, unlimited: unlimited)
    }

    /// A bundled route's normalized shape: {"ok":..., "error":..., "data":...}.
    private func unwrap(_ result: Result<Any, ProviderFailure>?) -> [String: Any] {
        guard let result else { return ["ok": false, "error": "provider data unavailable"] }
        switch result {
        case .success(let data): return ["ok": true, "data": data]
        case .failure(let failure): return ["ok": false, "error": failure.reason]
        }
    }
}
