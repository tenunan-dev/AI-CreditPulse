import Foundation

// Adapters ported from backend/plugin_api.py — all nine providers live.
// Credential resolution stays outside each cache entry where the Python
// adapter resolves it; each sample bundles its per-route failures locally so
// one decoration route can never blank another (the one-instant pattern).

/// Claude — subscription usage via GET api.anthropic.com/api/oauth/usage.
/// Credential order: CLAUDE_CODE_OAUTH_TOKEN in .env, then Claude Code's own
/// store (file first, then the macOS keychain). Token expiry is never judged
/// pre-emptively: the API's own 401 is the authoritative signal (ports claude()).
public struct ClaudeAdapter: ProviderAdapter {
    public init() {}
    public let id: String = "claude"
    public let label: String = "Claude"
    public let kind = ProviderResult.Kind.usage
    public let unit: String = "%"
    public let credentialHints: [String] = ["CLAUDE_CODE_OAUTH_TOKEN"]

    /// One cached sample: credential resolution and request together, so a
    /// cache hit touches neither the credentials file nor the keychain.
    struct Sample: @unchecked Sendable {
        let ok: Bool
        let error: String?
        let plan: String?
        let data: [String: Any]?
    }

    public func fetch() async -> ProviderResult {
        let override = EnvStore.shared.key("CLAUDE_CODE_OAUTH_TOKEN")
        let outcome: Result<Sample, ProviderFailure> = await ProviderHTTP.cached("claude") {
            var token = override
            var plan: String?
            if token == nil, let creds = ModelStore.claudeCredentials() {
                token = creds.token
                plan = creds.plan
            }
            guard let token, !token.isEmpty else {
                return Sample(ok: false, error: "no OAuth token", plan: nil, data: nil)
            }
            do {
                let payload = try await ProviderHTTP.get(
                    URL(string: "https://api.anthropic.com/api/oauth/usage")!,
                    headers: [
                        "Authorization": "Bearer \(token)",
                        "anthropic-beta": "oauth-2025-04-20",
                    ]) as! [String: Any]
                return Sample(ok: true, error: nil, plan: plan, data: payload)
            } catch {
                var reason = ProviderHTTP.safe(error)
                // An expired or revoked token answers 401 — verified live for an
                // expired and a garbage token. A 403 is an entitlement answer, so
                // it keeps its generic transport reason.
                if case .http(401)? = error as? HTTPError {
                    reason = "token expired — run `claude` once to refresh"
                }
                return Sample(ok: false, error: reason, plan: plan, data: nil)
            }
        }
        guard case .success(let sample) = outcome else {
            return .unavailable(id, label, kind: kind, unit: unit, error: "provider data unavailable")
        }
        guard sample.ok else {
            return .unavailable(id, label, kind: kind, unit: unit,
                                error: sample.error, plan: sample.plan)
        }
        guard let d = sample.data,
              d["five_hour"] != nil || d["seven_day"] != nil else {
            return .unavailable(id, label, kind: kind, unit: unit,
                                error: "provider data unavailable", plan: sample.plan)
        }
        let five = d["five_hour"] as? [String: Any] ?? [:]
        let week = d["seven_day"] as? [String: Any] ?? [:]
        let util = Norm.number(five["utilization"])
        let weeklyUtil = Norm.number(week["utilization"])
        // OAuth usage returns percentages (unlike the fractional rate-limit headers).
        let pct = util.map { ($0 * 10).rounded() / 10 }
        let weeklyPct = weeklyUtil.map { ($0 * 10).rounded() / 10 }
        var detail = "5h \(Norm.text(util))%"
        if d["seven_day"] != nil { detail += ", weekly \(Norm.text(weeklyUtil))%" }
        let sub = d["subscription"] as? [String: Any] ?? [:]
        let planText = (d["plan_type"] as? String)
            ?? (d["plan"] as? String)
            ?? (sub["plan"] as? String)
            ?? sample.plan
        return ProviderResult(
            id: id, label: label, kind: kind, value: pct, unit: unit, detail: detail,
            ok: true, error: nil, ts: Date(),
            plan: planText,
            renewalAt: Norm.date(sub["current_period_end"]),
            nextResetAt: Norm.reset(five), weeklyResetAt: Norm.reset(week),
            monthlyResetAt: nil,
            primaryUsagePercent: pct, weeklyUsagePercent: weeklyPct, monthlyUsagePercent: nil,
            limitReached: false, unlimited: false)
    }
}

/// Codex — ChatGPT subscription usage via GET chatgpt.com/backend-api/wham/usage,
/// credentials from ~/.codex/auth.json (ports codex()). A missing file and an
/// unparsable file are different messages, matching the Python try/except split.
public struct CodexAdapter: ProviderAdapter {
    public init() {}
    public let id: String = "codex"
    public let label: String = "Codex"
    public let kind = ProviderResult.Kind.usage
    public let unit: String = "%"
    public let credentialHints: [String] = []

    public func fetch() async -> ProviderResult {
        guard let auth = ModelStore.readJSON(Path.home + "/.codex/auth.json") else {
            return .unavailable(id, label, kind: kind, unit: unit, error: "no ~/.codex/auth.json")
        }
        let tokens = auth["tokens"] as? [String: Any] ?? [:]
        let token = (tokens["access_token"] as? String) ?? ""
        guard !token.isEmpty else {
            return .unavailable(id, label, kind: kind, unit: unit, error: "no access token")
        }
        let headers = [
            "Authorization": "Bearer \(token)",
            "chatgpt-account-id": (tokens["account_id"] as? String) ?? "",
        ]
        do {
            let payload = try await ProviderHTTP.get(
                URL(string: "https://chatgpt.com/backend-api/wham/usage")!,
                headers: headers) as! [String: Any]
            guard let rl = payload["rate_limit"] as? [String: Any] else {
                return .unavailable(id, label, kind: kind, unit: unit, error: "provider data unavailable")
            }
            let five = rl["primary_window"] as? [String: Any] ?? [:]
            let week = rl["secondary_window"] as? [String: Any] ?? [:]
            let pct = Norm.number(five["used_percent"])
            let weeklyPct = Norm.number(week["used_percent"])
            let plan = Norm.plan(payload["plan_type"])
            let detail = "5h \(Norm.text(five["used_percent"]))%, weekly \(Norm.text(week["used_percent"]))%, plan \(plan ?? "?")"
            let sub = payload["subscription"] as? [String: Any] ?? [:]
            // reset_after_seconds-based windows are anchored to the fetch instant.
            let observedAt = ProviderHTTP.observedAt("codex")
            return ProviderResult(
                id: id, label: label, kind: kind, value: pct, unit: unit, detail: detail,
                ok: true, error: nil, ts: Date(),
                plan: plan,
                renewalAt: Norm.date(sub["current_period_end"]),
                nextResetAt: Norm.reset(five, observedAt: observedAt),
                weeklyResetAt: Norm.reset(week, observedAt: observedAt),
                monthlyResetAt: nil,
                primaryUsagePercent: pct, weeklyUsagePercent: weeklyPct, monthlyUsagePercent: nil,
                limitReached: (rl["limit_reached"] as? Bool) == true, unlimited: false)
        } catch {
            return .unavailable(id, label, kind: kind, unit: unit, error: ProviderHTTP.safe(error))
        }
    }
}

/// Z.ai / GLM — coding-plan quota windows, or a probed PAYG funding state when
/// no Coding Plan is attached (ports zai()). Z.ai encodes an absent Coding Plan
/// as code 500 in an otherwise successful HTTP response, which is a normal
/// PAYG-account state — then a tiny 1-token chat probes whether the wallet runs.
public struct ZAIAdapter: ProviderAdapter {
    public init() {}
    public let id: String = "zai"
    public let label: String = "Z.ai / GLM"
    public let kind = ProviderResult.Kind.balance
    public let unit: String = "USD"
    public let credentialHints: [String] = ["GLM_API_KEY", "ZAI_API_KEY", "ZHIPU_API_KEY"]

    private static let noPlan = "No coding plan (PAYG only)"
    /// Keep the billable Z.ai funding check infrequent (PAYG_PROBE_CACHE_TTL).
    private static let probeTTL: TimeInterval = 15 * 60

    struct Sample: @unchecked Sendable {
        let error: String?        // authored transport/status reason on failure
        let data: [String: Any]?  // the quota envelope on success
    }

    struct ProbeSample: @unchecked Sendable {
        let payload: [String: Any]? // parsed success envelope, or parsed HTTP-error body
        let httpError: String?      // authored safe reason when HTTP errored
    }

    public func fetch() async -> ProviderResult {
        guard let key = EnvStore.shared.key(credentialHints) else {
            return .unavailable(id, label, kind: kind, unit: unit, error: "no API key")
        }
        let headers = ["Authorization": "Bearer \(key)"]

        let quotaOutcome: Result<Sample, ProviderFailure> = await ProviderHTTP.cached("zai:quota") {
            do {
                let payload = try await ProviderHTTP.get(
                    URL(string: "https://api.z.ai/api/monitor/usage/quota/limit")!,
                    headers: headers) as! [String: Any]
                return Sample(error: nil, data: payload)
            } catch {
                return Sample(error: ProviderHTTP.safe(error), data: nil)
            }
        }
        guard case .success(let quota) = quotaOutcome else {
            return .unavailable(id, label, kind: kind, unit: unit, error: "provider data unavailable")
        }
        guard let quotaData = quota.data else {
            return .unavailable(id, label, kind: kind, unit: unit, error: quota.error)
        }

        let noPlan = Norm.number(quotaData["code"]) == 500
            && (quotaData["success"] as? Bool) == false
            && (quotaData["msg"] as? String ?? "").lowercased().contains("coding plan")
        if noPlan {
            return await paygProbe(headers: headers)
        }

        guard let data = quotaData["data"] as? [String: Any],
              let limitsRaw = data["limits"] as? [Any],
              Norm.number(quotaData["code"]) == 200,
              (quotaData["success"] as? Bool) == true else {
            return .unavailable(id, label, kind: kind, unit: unit, error: "provider data unavailable")
        }
        // Z.ai renamed the plan windows' type to CREDIT_LIMIT; TOKENS_LIMIT is the
        // older spelling. A payload reporting one unit under both types is ambiguous,
        // so that window is published as absent rather than an order-dependent number.
        var byUnit: [Double: [String: Any]] = [:]
        var conflicted = Set<Double>()
        for raw in limitsRaw {
            guard let limit = raw as? [String: Any],
                  (limit["type"] as? String) == "TOKENS_LIMIT" || (limit["type"] as? String) == "CREDIT_LIMIT",
                  let unit = Norm.number(limit["unit"]) else { continue }
            if byUnit[unit] != nil { conflicted.insert(unit) } else { byUnit[unit] = limit }
        }
        for unit in conflicted { byUnit.removeValue(forKey: unit) }
        let five = byUnit[3] ?? [:]
        let weekly = byUnit[6] ?? [:]
        if five.isEmpty && weekly.isEmpty {
            return .unavailable(id, label, kind: kind, unit: unit, error: "provider data unavailable")
        }
        return ProviderResult(
            id: id, label: label, kind: kind, value: nil, unit: unit,
            detail: "GLM Coding Plan quota", ok: true, error: nil, ts: Date(),
            plan: "GLM Coding Plan", renewalAt: nil,
            nextResetAt: Norm.date(five["nextResetTime"]),
            weeklyResetAt: Norm.date(weekly["nextResetTime"]),
            monthlyResetAt: nil,
            primaryUsagePercent: Norm.number(five["percentage"]),
            weeklyUsagePercent: Norm.number(weekly["percentage"]),
            monthlyUsagePercent: nil,
            limitReached: false, unlimited: false)
    }

    /// PAYG probe: a 1-token chat classifies the wallet. Depleted is answered as an
    /// HTTP error carrying code 1113 / "insufficient balance"; funded completes.
    private func paygProbe(headers: [String: String]) async -> ProviderResult {
        let outcome: Result<ProbeSample, ProviderFailure> = await ProviderHTTP.cached("zai:probe", ttl: Self.probeTTL) {
            do {
                let (status, json) = try await ProviderHTTP.postRaw(
                    URL(string: "https://api.z.ai/api/paas/v4/chat/completions")!,
                    headers: headers,
                    body: ["model": "glm-5.3-flash",
                           "messages": [["role": "user", "content": "hi"]],
                           "max_tokens": 1])
                let payload = (json as? [String: Any]) ?? [:]
                if (200..<300).contains(status) { return ProbeSample(payload: payload, httpError: nil) }
                return ProbeSample(payload: payload, httpError: "provider request failed (HTTP \(status))")
            } catch {
                return ProbeSample(payload: nil, httpError: ProviderHTTP.safe(error))
            }
        }
        guard case .success(let probe) = outcome else {
            return .unavailable(id, label, kind: kind, unit: unit, error: "provider data unavailable")
        }
        let payload = probe.payload ?? [:]
        let errorDict = payload["error"] as? [String: Any] ?? [:]
        let codes = [Norm.number(payload["code"]), Norm.number(errorDict["code"])].compactMap { $0 }
        let messages = [payload["msg"], payload["message"], errorDict["message"]]
            .compactMap { $0 as? String }
        if codes.contains(1113) || messages.contains(where: { $0.lowercased().contains("insufficient balance") }) {
            return ProviderResult(
                id: id, label: label, kind: kind, value: 0.0, unit: unit,
                detail: "PAYG balance empty", ok: true, error: nil, ts: Date(),
                plan: Self.noPlan, renewalAt: nil, nextResetAt: nil, weeklyResetAt: nil,
                monthlyResetAt: nil, primaryUsagePercent: nil, weeklyUsagePercent: nil,
                monthlyUsagePercent: nil, limitReached: false, unlimited: false)
        }
        if let httpError = probe.httpError {
            return .unavailable(id, label, kind: kind, unit: unit, error: httpError)
        }
        // Funded — the chat answered; the wallet total is not exposed by the API.
        let completed = ((payload["choices"] as? [Any]).map { !$0.isEmpty } == true)
            || ((payload["id"] as? String)?.trimmingCharacters(in: .whitespaces).isEmpty == false)
        guard completed else {
            return .unavailable(id, label, kind: kind, unit: unit, error: "provider data unavailable")
        }
        return ProviderResult(
            id: id, label: label, kind: kind, value: nil, unit: unit,
            detail: "Funded (PAYG) - balance not exposed by API",
            ok: true, error: nil, ts: Date(),
            plan: Self.noPlan, renewalAt: nil, nextResetAt: nil, weeklyResetAt: nil,
            monthlyResetAt: nil, primaryUsagePercent: nil, weeklyUsagePercent: nil,
            monthlyUsagePercent: nil, limitReached: false, unlimited: false)
    }
}

/// OpenCode — rolling/weekly/monthly usage windows via GET
/// opencode.ai/zen/go/v1/usage. Keys from .env first, then the CLI's own
/// auth.json; each stored key is tried until one is entitled — a 401/403
/// refuses that credential, not the account (ports opencode()).
public struct OpenCodeAdapter: ProviderAdapter {
    public init() {}
    public let id: String = "opencode"
    public let label: String = "OpenCode"
    public let kind = ProviderResult.Kind.usage
    public let unit: String = "%"
    public let credentialHints: [String] = ["OPENCODE_API_KEY", "OPENCODE_ZEN_API_KEY", "OPENCODE_GO_API_KEY"]

    struct Sample: @unchecked Sendable {
        let ok: Bool
        let error: String?
        let data: [String: Any]?
    }

    public func fetch() async -> ProviderResult {
        var collected = EnvStore.shared.keyCandidates(credentialHints)
        for key in ModelStore.openCodeKeys() where !collected.contains(key) { collected.append(key) }
        let keys = collected  // immutable capture for the @Sendable closure
        guard !keys.isEmpty else {
            return .unavailable(id, label, kind: kind, unit: unit, error: "no API key")
        }

        let outcome: Result<Sample, ProviderFailure> = await ProviderHTTP.cached("opencode") {
            var lastError = "provider data unavailable"
            var refusedAll = false
            for key in keys {
                do {
                    let payload = try await ProviderHTTP.get(
                        URL(string: "https://opencode.ai/zen/go/v1/usage")!,
                        headers: ["Authorization": "Bearer \(key)"]) as! [String: Any]
                    return Sample(ok: true, error: nil, data: payload)
                } catch let error {
                    lastError = ProviderHTTP.safe(error)
                    // A refused credential moves on to the next key; every other
                    // failure is final. When EVERY credential is refused (the
                    // API's own `api_key_expired` code is common — keys don't
                    // renew with re-signing), say exactly what to do.
                    if case .http(let code)? = error as? HTTPError, code == 401 || code == 403 {
                        refusedAll = true
                        continue
                    }
                    refusedAll = false
                    break
                }
            }
            if refusedAll { lastError = "API key refused or expired — create a new one in OpenCode Console" }
            return Sample(ok: false, error: lastError, data: nil)
        }
        guard case .success(let sample) = outcome else {
            return .unavailable(id, label, kind: kind, unit: unit, error: "provider data unavailable")
        }
        guard sample.ok else {
            return .unavailable(id, label, kind: kind, unit: unit, error: sample.error)
        }
        guard let payload = sample.data, let usage = payload["usage"] as? [String: Any] else {
            return .unavailable(id, label, kind: kind, unit: unit, error: "provider data unavailable")
        }
        let rolling = usage["rolling"] as? [String: Any] ?? [:]
        let weekly = usage["weekly"] as? [String: Any] ?? [:]
        let monthly = usage["monthly"] as? [String: Any] ?? [:]
        let weeklyPct = Norm.number(weekly["percent"])
        let monthlyPct = Norm.number(monthly["percent"])
        let pct = Norm.number(rolling["percent"])
        var detail = "5h \(Norm.text(pct))%, weekly \(Norm.text(weeklyPct))%"
        if (monthly["status"] as? String) == "rate-limited" {
            detail += " (monthly \(Norm.text(monthlyPct))% — limited)"
        }
        let sub = payload["subscription"] as? [String: Any] ?? [:]
        let windows = [rolling, weekly, monthly]
        return ProviderResult(
            id: id, label: label, kind: kind, value: pct, unit: unit, detail: detail,
            ok: true, error: nil, ts: Date(),
            plan: (payload["plan"] as? String) ?? (sub["plan"] as? String),
            renewalAt: Norm.date(sub["current_period_end"]),
            nextResetAt: Norm.reset(rolling), weeklyResetAt: Norm.reset(weekly),
            monthlyResetAt: Norm.reset(monthly),
            primaryUsagePercent: pct, weeklyUsagePercent: weeklyPct, monthlyUsagePercent: monthlyPct,
            limitReached: windows.contains { ($0["status"] as? String) == "rate-limited" },
            unlimited: false)
    }
}

/// CommandCode — credits via /alpha/billing/credits, plus the monthly billing
/// period (/alpha/billing/subscriptions) and period consumption
/// (/alpha/usage/summary). All three routes sample under ONE cache entry: the
/// monthly gauge mixes numbers from two of them, and separate TTLs could pair a
/// fresh grant with the previous period's consumption across a rollover
/// (ports commandcode()).
public struct CommandCodeAdapter: ProviderAdapter {
    public init() {}
    public let id: String = "commandcode"
    public let label: String = "CommandCode"
    public let kind = ProviderResult.Kind.balance
    public let unit: String = "credits"
    public let credentialHints: [String] = []

    struct Sample: @unchecked Sendable {
        var credits: [String: Any]?       // billing/credits payload
        var subscription: [String: Any]?  // billing/subscriptions payload
        var usage: [String: Any]?         // usage/summary payload
        var faults: [String: String] = [:] // route → authored reason, local per route
    }

    public func fetch() async -> ProviderResult {
        guard let token = ModelStore.commandCodeAuth() else {
            return .unavailable(id, label, kind: kind, unit: unit, error: "no ~/.commandcode/auth.json")
        }
        let headers = [
            "Authorization": "Bearer \(token)",
            "Content-Type": "application/json",
            "User-Agent": "cli",
            "x-command-code-version": "1.53.0",
        ]

        let outcome: Result<Sample, ProviderFailure> = await ProviderHTTP.cached("commandcode") {
            /// One instant, three routes; each failure is local to its own key.
            var sample = Sample()
            for (name, path) in [("credits", "billing/credits"),
                                 ("subscription", "billing/subscriptions"),
                                 ("usage", "usage/summary")] {
                do {
                    let payload = try await ProviderHTTP.get(
                        URL(string: "https://api.commandcode.ai/alpha/\(path)")!,
                        headers: headers) as? [String: Any]
                    switch name {
                    case "credits": sample.credits = payload
                    case "subscription": sample.subscription = payload
                    default: sample.usage = payload
                    }
                } catch {
                    sample.faults[name] = ProviderHTTP.safe(error)
                }
            }
            return sample
        }
        guard case .success(let sample) = outcome else {
            return .unavailable(id, label, kind: kind, unit: unit, error: "provider data unavailable")
        }
        let balancePayload = sample.credits ?? [:]
        let credits = balancePayload["credits"] as? [String: Any] ?? [:]
        if credits.isEmpty {
            // Prefer the credits route's own failure; fall back to a bundle-level one.
            return .unavailable(id, label, kind: kind, unit: unit,
                                error: sample.faults["credits"] ?? sample.faults.values.first
                                    ?? "provider data unavailable")
        }
        let total = ["monthlyCredits", "purchasedCredits", "freeCredits"]
            .reduce(0.0) { $0 + (Norm.number(credits[$1]) ?? 0) }
        let wl = balancePayload["windowLimits"] as? [String: Any] ?? [:]
        let five = wl["fiveHour"] as? [String: Any] ?? [:]
        let weekly = wl["weekly"] as? [String: Any] ?? [:]
        let subscriptionData = (sample.subscription as? [String: Any])?["data"] as? [String: Any] ?? [:]
        let summary = sample.usage ?? [:]
        let periodEnd = Norm.date(subscriptionData["currentPeriodEnd"])

        func percent(_ window: [String: Any]) -> Double? {
            guard let used = Norm.number(window["used"]),
                  let cap = Norm.number(window["cap"]), cap > 0 else { return nil }
            return used / cap * 100
        }
        // Non-boolean encodings ("true", 1) are deliberately ignored: the provider
        // returns real JSON booleans. `limited` only corroborates — a fully
        // consumed window is a hit even when `exceeded` never appears; `limited`
        // alone is not one (verified live: limited=True at 0.07% usage).
        func hit(_ window: [String: Any]) -> Bool {
            if (window["exceeded"] as? Bool) == true { return true }
            if (wl["limited"] as? Bool) == true, let p = percent(window), p >= 100 { return true }
            return false
        }

        var detail = "5h \(Norm.text(five["used"]))/\(Norm.text(five["cap"])) credits, "
            + "weekly cap \(Norm.text(weekly["cap"])) credits"
        // The API publishes no monthly cap, so the billing period's grant is derived
        // from the two numbers it does report: monthly credits remaining plus monthly
        // credits consumed. Guards: the summary must be scoped to the billing period
        // (a lifetime figure is never a monthly one) and the period end must be real
        // and still ahead of now (a period that has ended, or a rollover caught
        // mid-sampling, can pair numbers from two different periods) — a percentage
        // never travels without a live month. Assumes the monthly bucket is what
        // those requests consumed; top-ups live in purchasedCredits and are outside
        // this gauge.
        let basis = (summary["periodBasis"] as? String ?? "")
            .trimmingCharacters(in: .whitespaces).lowercased()
        let consumed = basis == "billing-period" ? Norm.number(summary["totalMonthlyCredits"]) : nil
        let remaining = Norm.number(credits["monthlyCredits"])
        var monthlyPct: Double?
        if let end = periodEnd, end > Date(),
           let consumed, let remaining, consumed + remaining > 0 {
            monthlyPct = ((max(0.0, min(100.0, consumed / (consumed + remaining) * 100))) * 10)
                .rounded() / 10
        }
        // The subscriptions route is the plan's only source: the credits payload
        // carries no plan field (verified live). planId is "individual-goat" on a
        // Go/GOAT account; the raw string passes through verbatim.
        let plan = Norm.plan(subscriptionData["planId"])
        if let plan { detail += ", plan \(plan)" }
        let fallbackRenewal = ((balancePayload["subscription"] as? [String: Any])?["current_period_end"])
            .flatMap { Norm.date($0) }
        return ProviderResult(
            id: id, label: label, kind: kind, value: (total * 100).rounded() / 100, unit: unit,
            detail: detail, ok: true, error: nil, ts: Date(),
            plan: plan,
            renewalAt: periodEnd ?? fallbackRenewal,
            nextResetAt: Norm.reset(five), weeklyResetAt: Norm.reset(weekly),
            monthlyResetAt: periodEnd,
            primaryUsagePercent: percent(five), weeklyUsagePercent: percent(weekly),
            monthlyUsagePercent: monthlyPct,
            // The top-level windowLimits.exceeded is present-but-null on the live
            // account, so it is honoured only if a provider ever sets it true.
            limitReached: (wl["exceeded"] as? Bool) == true || hit(five) || hit(weekly),
            unlimited: false)
    }
}

/// Nous Portal — paid credits via GET {portal}/api/oauth/account. Token: an .env
/// override, then the Hermes agent's auth.json (providers.nous, then any
/// credential_pool.nous entry) (ports nous()).
public struct NousAdapter: ProviderAdapter {
    public init() {}
    public let id: String = "nous"
    public let label: String = "Nous Portal"
    public let kind = ProviderResult.Kind.balance
    public let unit: String = "USD"
    public let credentialHints: [String] = ["NOUS_PORTAL_TOKEN", "HERMES_CUSTOM_NOUS_TOKEN"]

    public func fetch() async -> ProviderResult {
        let envToken = EnvStore.shared.key(credentialHints)
        let local = envToken == nil ? ModelStore.nousCredential() : nil
        guard let bearer = envToken ?? local?.token else {
            return .unavailable(id, label, kind: kind, unit: unit, error: "no OAuth token")
        }
        var base = local?.portalBaseURL ?? "https://portal.nousresearch.com"
        while base.hasSuffix("/") { base.removeLast() }
        let outcome: Result<[String: Any], ProviderFailure> = await ProviderHTTP.cached("nous") {
            try await ProviderHTTP.get(
                URL(string: "\(base)/api/oauth/account")!,
                headers: ["Authorization": "Bearer \(bearer)"]) as! [String: Any]
        }
        guard case .success(let d) = outcome else {
            return .unavailable(id, label, kind: kind, unit: unit, error: "provider data unavailable")
        }
        guard d["paid_service_access"] != nil else {
            return .unavailable(id, label, kind: kind, unit: unit, error: "provider data unavailable")
        }
        let paid = d["paid_service_access"] as? [String: Any] ?? [:]
        let sub = d["subscription"] as? [String: Any] ?? [:]
        guard let total = Norm.number(paid["total_usable_credits"]) else {
            return .unavailable(id, label, kind: kind, unit: unit, error: "provider data unavailable")
        }
        let renewal = Norm.date(sub["current_period_end"])
        let renewalText = renewal.map { Norm.Formatter.dayOnly.string(from: $0) } ?? "?"
        let detail = "plan \(Norm.plan(sub["plan"]) ?? "?"), renews \(renewalText)"
        // Monthly allowance gauge: credits granted for the period versus what is
        // left. The clamp hides one ambiguity on purpose — rollover or purchased
        // credits can leave more than the grant, which reads as 0% rather than a
        // negative use.
        let granted = Norm.number(sub["monthly_credits"])
        let left = Norm.number(sub["credits_remaining"])
        var monthlyPct: Double?
        if let granted, granted > 0, let left {
            monthlyPct = ((max(0.0, min(1.0, (granted - left) / granted)) * 100) * 10).rounded() / 10
        }
        return ProviderResult(
            id: id, label: label, kind: kind, value: (total * 100).rounded() / 100, unit: unit,
            detail: detail, ok: true, error: nil, ts: Date(),
            plan: Norm.plan(sub["plan"]),
            renewalAt: renewal, nextResetAt: nil, weeklyResetAt: nil,
            monthlyResetAt: renewal,
            primaryUsagePercent: nil, weeklyUsagePercent: nil, monthlyUsagePercent: monthlyPct,
            limitReached: false, unlimited: false)
    }
}

/// ILMU (YTL AI Labs) — plan token grant + PAYG wallet (MYR) via the Console API.
/// The console speaks session cookie, not API key — every route answers 401 for a
/// bare `sk-` key, so the pasted `ilmu_session` value is the only usable
/// credential. Headline is the PAYG wallet; subscription beneath it. The plan is
/// a ~30-day token cycle — monthly is the only window, so no primary/weekly
/// percentage is published (ports ilmu()).
public struct ILMUAdapter: ProviderAdapter {
    public init() {}
    public let id: String = "ilmu"
    public let label: String = "ILMU"
    public let kind = ProviderResult.Kind.usage
    public let unit: String = "%"
    public let credentialHints: [String] = ["HERMES_CUSTOM_ILMU_COOKIE", "ILMU_CONSOLE_COOKIE"]
    private static let baseURL = "https://console.ilmu.ai"
    private static let cookieName = "ilmu_session"

    struct Route: @unchecked Sendable {
        let ok: Bool
        let data: [String: Any]?
        let error: String?
    }

    struct Sample: @unchecked Sendable {
        let subscription: Route
        let payg: Route
    }

    public func fetch() async -> ProviderResult {
        guard let cookie = EnvStore.shared.key(credentialHints) else {
            return .unavailable(id, label, kind: kind, unit: unit, error: "no console session cookie")
        }
        // The stored value is the cookie's bare value; a full Cookie header also works.
        let headers = ["Cookie": cookie.contains("=") ? cookie : "\(Self.cookieName)=\(cookie)",
                       "Accept": "application/json"]
        let outcome: Result<Sample, ProviderFailure> = await ProviderHTTP.cached("ilmu") {
            /// Both routes under one cache entry, each failure local to its own
            /// key — a failed wallet route must never cost the subscription.
            func one(_ path: String) async -> Route {
                do {
                    let payload = try await ProviderHTTP.get(
                        URL(string: Self.baseURL + path)!, headers: headers) as! [String: Any]
                    return Route(ok: true, data: payload, error: nil)
                } catch {
                    var reason = ProviderHTTP.safe(error)
                    // 401/403 is the cookie speaking: it expired, and the fix
                    // (re-paste) is something the generic transport text cannot say.
                    if case .http(let code)? = error as? HTTPError, code == 401 || code == 403 {
                        reason = "console session expired - re-paste the cookie"
                    }
                    return Route(ok: false, data: nil, error: reason)
                }
            }
            return Sample(subscription: await one("/api/subscriptions/current"),
                          payg: await one("/api/payg/balance"))
        }
        guard case .success(let sample) = outcome else {
            return .unavailable(id, label, kind: kind, unit: unit, error: "provider data unavailable")
        }
        guard sample.subscription.ok, let subData = sample.subscription.data else {
            return .unavailable(id, label, kind: kind, unit: unit, error: sample.subscription.error)
        }
        let data = (subData["data"] as? [String: Any])?["data"] as? [String: Any] ?? [:]
        let subs = ((data["subscriptions"] as? [Any]) ?? []).compactMap { $0 as? [String: Any] }
        if subs.isEmpty {
            return .unavailable(id, label, kind: kind, unit: unit, error: "provider data unavailable")
        }
        // The active entry is the live grant; a trailing cancelled or expired entry
        // must not mask it. The top-level tokensUsed is dead weight (observed 0
        // while the entry below reported 24.4M used), so only the entry's own
        // numbers are read.
        let active = subs.first { ($0["status"] as? String) == "active" } ?? subs[0]
        var grant = Norm.number(active["seatTokensGranted"])
            ?? Norm.number(active["tokenGrant"])
            ?? Norm.number(data["tokenLimit"])
        var left = Norm.number(active["tokensRemaining"]) ?? Norm.number(data["tokenBalance"])
        let used = Norm.number(active["tokensUsed"])
        // Top-up packs extend the same pool, so their grant and remainder fold into
        // the period figures; a missing pack field reads as 0.
        if let l = left { left = l + (Norm.number(active["packTokensRemaining"]) ?? 0) }
        if let g = grant { grant = g + (Norm.number(active["packTokensGranted"]) ?? 0) }
        if grant == nil, let l = left, let u = used { grant = u + l }
        let periodEnd = Norm.date(active["currentPeriodEnd"]) ?? Norm.date(data["currentPeriodEnd"])
        // A percentage only while the period is live: once it has ended, the
        // figures may already belong to the next period, and a dead period's gauge
        // must not render.
        let live = periodEnd.map { $0 > Date() } ?? false
        var pct: Double?
        if (active["status"] as? String) == "active", live,
           let g = grant, g > 0, let l = left {
            pct = ((max(0.0, min(100.0, (g - l) / g * 100))) * 10).rounded() / 10
        }
        let periodEndISO = periodEnd.map { Norm.Formatter.dayOnly.string(from: $0) }
        var parts: [String] = []
        if let g = grant, let l = left {
            parts.append("\(Self.tokens(l)) of \(Self.tokens(g)) tokens left")
        }
        if let pct {
            if let iso = periodEndISO { parts.append("resets \(String(iso.prefix(10)))") }
        } else if (active["status"] as? String) == "active", let iso = periodEndISO, !live {
            // Say why there is no gauge: the period ended, which a bare absence cannot.
            parts.append("plan period ended")
        }
        let autoRenew = active["autoRenew"] ?? data["autoRenew"]
        if Self.truthy(active["cancelledAt"] ?? data["cancelledAt"]), (autoRenew as? Bool) != true {
            parts.append("plan cancelled (no auto-renew)")
        }
        let plan = Norm.plan(active["planName"]) ?? Norm.plan(active["planId"])
            ?? Norm.plan(data["planName"]) ?? Norm.plan(data["planId"])
        // The PAYG wallet is the headline and the subscription the detail beneath
        // it. Money fields arrive as strings; Norm.number parses them.
        let paygData = ((sample.payg.data ?? [:])["data"] as? [String: Any])?["data"] as? [String: Any]
        let credit = sample.payg.ok ? Norm.number(paygData?["available_myr"]) : nil
        // Wallet unreadable → the headline falls back to the plan percentage, a
        // number the provider really published: no invented 0.00 credit, no bare —
        // while one exists. A wallet answering 0.00 is genuinely empty and keeps 0.
        // kind stays "usage" (the subscription window), so the MYR figure never
        // enters the USD-only combined balance.
        let value = credit ?? pct
        let headlineUnit = credit != nil ? "MYR" : "%"
        return ProviderResult(
            id: id, label: label, kind: kind, value: value, unit: headlineUnit,
            detail: parts.joined(separator: " · "), ok: true, error: nil, ts: Date(),
            plan: plan, renewalAt: periodEnd, nextResetAt: nil, weeklyResetAt: nil,
            monthlyResetAt: periodEnd,
            primaryUsagePercent: nil, weeklyUsagePercent: nil, monthlyUsagePercent: pct,
            limitReached: pct != nil && (left.map { $0 <= 0 } ?? false), unlimited: false)
    }

    /// Python truthiness over JSON values, for `cancelled_at`-style flags
    /// (a bare `if value` in the plugin).
    static func truthy(_ value: Any?) -> Bool {
        if let b = value as? Bool { return b }
        if let n = Norm.number(value) { return n != 0 }
        if let s = value as? String { return !s.trimmingCharacters(in: .whitespaces).isEmpty }
        return false
    }

    /// Compact display form for token counts: '?' when absent, M/k units
    /// otherwise. ILMU grants run to tens of millions of tokens, so a raw figure
    /// would dominate the detail line; one decimal is enough, and a whole ".0"
    /// beside it is noise (50M, not 50.0M) (ports `_tokens`).
    static func tokens(_ value: Any?) -> String {
        guard let n = Norm.number(value) else { return "?" }
        if n >= 1e6 {
            var s = String(format: "%.1f", n / 1e6)
            if s.hasSuffix(".0") { s.removeLast(2) }
            return s + "M"
        }
        if n >= 1e3 { return String(format: "%.0f", n / 1e3) + "k" }
        return String(format: "%.0f", n)
    }
}
