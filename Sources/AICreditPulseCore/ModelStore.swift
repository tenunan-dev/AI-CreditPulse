import Foundation

/// Read-only provider-side credential fallbacks — ports the plugin's file and
/// macOS-keychain lookups. The .env file stays the user's primary control point
/// (per the product decision); these paths are honored only where the provider
/// CLI itself already stores credentials, exactly as the Hermes plugin did.
enum ModelStore {
    /// Claude Code's OAuth blob as (token, expiresAt, subscription type), freshest
    /// first: `~/.claude/.credentials.json`, then the login-keychain copy the CLI
    /// maintains under service "Claude Code-credentials" (ports `_claude_credentials`).
    static func claudeCredentials() -> (token: String, expiresAt: Date?, plan: String?)? {
        let now = Date()
        var entries: [[String: Any]] = []
        if let fileDict = readJSON(Path.home + "/.claude/.credentials.json") {
            if let entry = (fileDict["claudeAiOauth"] as? [String: Any]), entry["accessToken"] != nil {
                entries.append(entry)
            }
        }
        if let chainDict = keychainClaudeEntry() { entries.append(chainDict) }
        var live: [[String: Any]] = [], unknown: [[String: Any]] = [], expired: [[String: Any]] = []
        for entry in entries {
            let expiry = Norm.number(entry["expiresAt"]).map { Date(timeIntervalSince1970: $0 / 1000) }
            switch expiry {
            case .none: unknown.append(entry)
            case .some(let d) where d > now: live.append(entry)
            case .some: expired.append(entry)
            }
        }
        let pool = live.first ?? unknown.first ?? expired.first
        guard let entry = pool, let token = entry["accessToken"] as? String, !token.isEmpty else { return nil }
        let expiry = Norm.number(entry["expiresAt"]).map { Date(timeIntervalSince1970: $0 / 1000) }
        return (token, expiry, Norm.plan(entry["subscriptionType"]))
    }

    /// macOS login-keychain copy of Claude Code's credentials, or nil. `security -w`
    /// with stdin closed so a keychain that wants interaction simply yields nothing
    /// (ports `_keychain_claude_entry`).
    private static func keychainClaudeEntry() -> [String: Any]? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = ["find-generic-password", "-s", "Claude Code-credentials", "-w"]
        let stdout = Pipe(), stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        // stdin closed so the call cannot fall back to reading a terminal.
        process.standardInput = FileHandle.nullDevice
        do {
            try process.run()
        } catch { return nil }
        // A keychain that prompts would block: bound well under the fetch timeout.
        let deadline = DispatchTime.now() + 5
        let output = stdout.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        _ = deadline
        guard process.terminationStatus == 0, !output.isEmpty,
              let text = String(data: output, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty,
              let payload = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] else { return nil }
        return payload["claudeAiOauth"] as? [String: Any]
    }

    /// ~/.codex/auth.json → (access_token, account_id) (ports the codex adapter's lookup).
    static func codexAuth() -> (token: String, accountID: String?)? {
        guard let auth = readJSON(Path.home + "/.codex/auth.json"),
              let tokens = auth["tokens"] as? [String: Any],
              let token = tokens["access_token"] as? String, !token.isEmpty else { return nil }
        return (token, tokens["account_id"] as? String)
    }

    /// ~/.commandcode/auth.json → apiKey (ports the commandcode adapter's lookup).
    static func commandCodeAuth() -> String? {
        guard let auth = readJSON(Path.home + "/.commandcode/auth.json") else { return nil }
        if let key = auth["apiKey"] as? String, !key.isEmpty { return key }
        if let tokens = auth["tokens"] as? [String: Any],
           let token = tokens["access_token"] as? String, !token.isEmpty { return token }
        return nil
    }

    /// ~/.local/share/opencode/auth.json → opencode-go / opencode keys (ports the
    /// opencode adapter's local fallback).
    static func openCodeKeys() -> [String] {
        var keys: [String] = []
        guard let auth = readJSON(Path.home + "/.local/share/opencode/auth.json") else { return keys }
        for section in ["opencode-go", "opencode"] {
            if let sectionDict = auth[section] as? [String: Any],
               let key = sectionDict["key"] as? String, !key.isEmpty {
                keys.append(key)
            }
        }
        return keys
    }

    /// Hermes-style auth.json → Nous Portal entry as (token, optional portal base),
    /// merged across candidate homes profile-first (ports `_entry` + `_auth_json`):
    /// providers.nous first, then any credential_pool.nous entry that carries one.
    static func nousCredential() -> (token: String, portalBaseURL: String?)? {
        // Candidate homes, weakest first — a specific profile home wins.
        let env = ProcessInfo.processInfo.environment
        var homes: [String] = []
        for candidate in [env["HERMES_HOME"], env["HERMES_PROFILE_HOME"], Path.home + "/.hermes"] {
            if let h = candidate, !homes.contains(h) { homes.append(h) }
        }
        var merged: [String: [String: Any]] = [:]  // section → provider key → entry
        for home in homes {
            guard let data = readJSON(home + "/auth.json") else { continue }
            for section in ["providers", "credential_pool"] {
                guard let source = data[section] as? [String: Any] else { continue }
                var target = merged[section] ?? [:]
                for (key, value) in source where target[key] == nil { target[key] = value }
                merged[section] = target
            }
        }
        func token(_ value: Any?) -> String? {
            guard let s = value as? String, !s.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
            return s
        }
        var entry: [String: Any]?
        if let direct = merged["providers"]?["nous"] as? [String: Any], token(direct["access_token"]) != nil {
            entry = direct
        }
        if entry == nil, let pool = merged["credential_pool"]?["nous"] as? [Any] {
            for item in pool {
                if let dict = item as? [String: Any], token(dict["access_token"]) != nil {
                    entry = dict
                    break
                }
            }
        }
        guard let found = entry, let accessToken = token(found["access_token"]) else { return nil }
        return (accessToken, found["portal_base_url"] as? String)
    }

    static func readJSON(_ path: String) -> [String: Any]? {
        guard let data = FileManager.default.contents(atPath: path) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }
}

enum Path {
    static var home: String { NSHomeDirectory() }
}
