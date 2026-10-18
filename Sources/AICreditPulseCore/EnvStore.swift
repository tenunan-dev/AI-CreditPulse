import Foundation
import Dispatch

/// Reads API keys from the app's local `.env` (KEY=VALUE). Ports the plugin's
/// `_load_env` / `_refresh_env`: the file is re-read whenever its mtime changes,
/// so a rotated key becomes visible without restarting the app.
///
/// Location: ~/Library/Application Support/AI CreditPulse/.env
/// The Settings UI writes this file; hand-editing works too.
public final class EnvStore: @unchecked Sendable {
    public static let shared = EnvStore()

    public static var defaultURL: URL { overrideURL ?? standardURL }

    private static let standardURL = FileManager.default
        .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("AI CreditPulse", isDirectory: true)
        .appendingPathComponent(".env")

    /// Test-only override: when set (smoke), every operation targets that URL
    /// instead of the user's real key file — headless tests must never be able
    /// to destroy stored keys.
    nonisolated(unsafe) public static var overrideURL: URL?

    private var values: [String: String] = [:]
    private var watchedPath: String?
    private var watcher: DispatchSourceFileSystemObject?
    private let lock = NSLock()

    private init() {
        _ = load()
        watch()
    }

    private func load() -> [String: String] {
        let path = Self.defaultURL.path
        var pairs: [String: String] = [:]
        guard let text = try? String(contentsOf: Self.defaultURL, encoding: .utf8) else {
            return pairs
        }
        _ = path
        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#"), line.contains("=") else { continue }
            let parts = line.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2 else { continue }
            // A continuation of a value that wrapped past its line parses as a
            // "name" that starts with a quote — never a key.
            let key = String(parts[0]).trimmingCharacters(in: .whitespaces)
            if key.hasPrefix("\"") || key.hasPrefix("'") { continue }
            var value = String(parts[1]).trimmingCharacters(in: .whitespaces)
            // Port of the Python reader's quote stripping.
            if value.count >= 2 {
                for quote in ["\"", "'"] where value.hasPrefix(quote) && value.hasSuffix(quote) {
                    value = String(value.dropFirst().dropLast())
                }
            }
            pairs[key] = value
        }
        watchedPath = Self.defaultURL.path
        return pairs
    }

    /// Key by one or more names, first non-empty wins (ports `_key`). Reads the
    /// .env each call through the mtime-guarded refresh; process env follows.
    public func key(_ names: String...) -> String? {
        key(Array(names))
    }

    public func key(_ names: [String]) -> String? {
        refreshIfChanged()
        lock.lock(); defer { lock.unlock() }
        return keyNoLock(names)
    }

    /// Every configured value for these names (env first, then process
    /// environment), deduplicated. Port of the plugin's `_key_candidates`:
    /// one credential can be refused while another is entitled, so a list.
    public func keyCandidates(_ names: [String]) -> [String] {
        refreshIfChanged()
        lock.lock(); defer { lock.unlock() }
        var found: [String] = []
        for n in names {
            if let v = values[n], !v.isEmpty, !found.contains(v) { found.append(v) }
        }
        let process = ProcessInfo.processInfo.environment
        for n in names {
            if let v = process[n], !v.isEmpty, !found.contains(v) { found.append(v) }
        }
        return found
    }

    private func keyNoLock(_ names: [String]) -> String? {
        for n in names {
            if let v = values[n], !v.isEmpty { return v }
        }
        for n in names {
            if let v = ProcessInfo.processInfo.environment[n], !v.isEmpty { return v }
        }
        return nil
    }

    private func refreshIfChanged() {
        lock.lock(); defer { lock.unlock() }
        let path = Self.defaultURL
        let mtime = (try? path.resourceValues(forKeys: [.contentModificationDateKey]))?
            .contentModificationDate
        if mtime != lastMtime {
            values = load()
            lastMtime = mtime
        }
    }

    private var lastMtime: Date?

    /// Writes `update` into .env, preserving comments and untouched keys.
    /// Values are quoted-safe: a value containing `"` is stored single-quoted.
    public func update(_ update: [String: String]) throws {
        lock.lock(); defer { lock.unlock() }
        let dir = Self.defaultURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var lines: [String] = []
        if let text = try? String(contentsOf: Self.defaultURL, encoding: .utf8) {
            lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        }
        var written = Set<String>()
        var result: [String] = []
        for rawLine in lines {
            let trimmed = rawLine.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("#") || trimmed.isEmpty {
                result.append(rawLine)
                continue
            }
            guard trimmed.contains("=") else {
                // Not a KEY=VALUE pair and not a comment: an orphan fragment
                // (e.g. a leftover quote from a value that once wrapped).
                continue
            }
            let name = trimmed.split(separator: "=", maxSplits: 1)[0]
                .trimmingCharacters(in: .whitespaces)
            if name.hasPrefix("\"") || name.hasPrefix("'") {
                // A continuation of a value that wrapped past its line: not a key.
                continue
            }
            if let v = update[name] {
                written.insert(name)
                result.append("\(name)=\(quoted(v))")
            } else {
                result.append(rawLine)
            }
        }
        // Append keys not present in the file yet.
        for (name, v) in update where !written.contains(name) {
            result.append("\(name)=\(quoted(v))")
        }
        var text = result.joined(separator: "\n")
        if !text.hasSuffix("\n") { text += "\n" }
        try text.write(to: Self.defaultURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: Self.defaultURL.path)
        values = load()
        lastMtime = (try? Self.defaultURL.resourceValues(forKeys: [.contentModificationDateKey]))?
            .contentModificationDate
    }

    private func quoted(_ value: String) -> String {
        // Credential pastes can come with trailing newlines (or a whole
        // multi-line clipboard): a newline inside a value breaks the one-line
        // KEY=VALUE format, splitting the file and orphaning quote fragments —
        // which then hid saved keys. Trim, and keep values single-line.
        let clean = value
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return clean.contains("\"") ? "'\(clean)'" : "\"\(clean)\""
    }

    // MARK: hot-reload watcher (ports the mtime polling half of `_refresh_env`)

    private func watch() {
        let path = Self.defaultURL.path
        guard !path.isEmpty else { return }
        let fd = open(path, O_EVTONLY)
        guard fd >= 0 else { return }  // file may not exist yet; refreshIfChanged covers it
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd, eventMask: [.write, .rename, .delete], queue: .main)
        source.setEventHandler { [weak self] in
            guard let self else { return }
            self.lock.lock()
            self.values = self.load()
            self.lastMtime = (try? Self.defaultURL.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate
            self.lock.unlock()
            NotificationCenter.default.post(name: .envStoreDidChange, object: nil)
        }
        source.setCancelHandler { close(fd) }
        source.resume()
        watcher = source
    }

    deinit { watcher?.cancel() }
}

extension Notification.Name {
    public static let envStoreDidChange = Notification.Name("EnvStoreDidChange")
}
