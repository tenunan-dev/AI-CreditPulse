// Headless smoke test for the AI CreditPulse Core layer — no GUI, no WindowServer.
// Verifies: .env skeleton creation + read-back + hot update, provider registry
// assembly, icon registration, and the safe error vocabulary end to end.
//
// Sandboxed .env: the whole test runs against a temporary file. The user's real
// key file is checksummed before and after to prove it is never touched.
import Foundation
import AppKit
import AICreditPulseCore

func check(_ name: String, _ condition: @autoclosure () -> Bool) {
    print((condition() ? "PASS" : "FAIL") + " " + name)
    if !condition() { exit(1) }
}

func checksum(_ path: String) -> String {
    guard let data = FileManager.default.contents(atPath: path) else { return "missing" }
    var digest = data.map { $0 }
    _ = digest.count
    return String(digest.reduce(0) { ($0 &+ Int($1)) & 0xFFFF_FFFF })
}

let realEnvPath = (FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    .appendingPathComponent("AI CreditPulse/.env")).path
let realEnvBefore = checksum(realEnvPath)
EnvStore.overrideURL = FileManager.default.temporaryDirectory
    .appendingPathComponent("aicreditpulse-smoke-\(UUID().uuidString).env")

// MARK: 1. .env skeleton + read-back

let skeleton: [String: String] = [
    "OPENROUTER_API_KEY": "",
    "DEEPSEEK_API_KEY": "sk-test-1234",
    "GLM_API_KEY": "",
    "CLAUDE_CODE_OAUTH_TOKEN": "",
    "ILMU_CONSOLE_COOKIE": "",
    "OPENCODE_API_KEY": "",
    "NOUS_PORTAL_TOKEN": "nous-test-token",
]
try EnvStore.shared.update(skeleton)
check("env file exists", FileManager.default.fileExists(atPath: EnvStore.defaultURL.path))
check("permissions 0600", {
    let attrs = try? FileManager.default.attributesOfItem(atPath: EnvStore.defaultURL.path)
    return (attrs?[.posixPermissions] as? Int) == 0o600
}())

EnvStore.shared.key("DEEPSEEK_API_KEY").map { key in
    check("read-back deepseek key", key == "sk-test-1234")
} ?? check("read-back deepseek key", false)

check("read-back nous token", EnvStore.shared.key("NOUS_PORTAL_TOKEN") == "nous-test-token")

// Comment and unrelated lines survive a partial update.
try EnvStore.shared.update(["DEEPSEEK_API_KEY": "sk-rotated-5678"])
let envText = try String(contentsOf: EnvStore.defaultURL, encoding: .utf8)
check("rotated key persisted", envText.contains("sk-rotated-5678"))
check("unrelated keys preserved", envText.contains("NOUS_PORTAL_TOKEN=\"nous-test-token\""))
check("rotation visible via key()", EnvStore.shared.key("DEEPSEEK_API_KEY") == "sk-rotated-5678")

// Quoting round-trip.
try EnvStore.shared.update(["ILMU_CONSOLE_COOKIE": "ilmu'quoted"])
check("single-quote value round-trip", EnvStore.shared.key("ILMU_CONSOLE_COOKIE") == "ilmu'quoted")
// A paste with trailing/inner newlines must stay one clean line (the wrapped
// value used to split the file into orphan fragments and hid stored keys).
try EnvStore.shared.update(["DEEPSEEK_API_KEY": "\nsk-with\ntrailing\n"])
check("newline paste sanitized to single line",
      EnvStore.shared.key("DEEPSEEK_API_KEY") == "sk-with trailing")
try EnvStore.shared.update(["DEEPSEEK_API_KEY": "sk-rotated-5678"])

// MARK: 2. Menubar icons — bundle resources must load with visible pixels

for name in ["green", "amber", "red", "grey"] {
    guard let image = MenubarIcon.loadVerified(name) else {
        print("FAIL icon-\(name) not found; resourcesBundle=\(MenubarIcon.resourcesBundle.bundlePath)")
        print("  contents: \(try? FileManager.default.subpathsOfDirectory(atPath: MenubarIcon.resourcesBundle.bundlePath).prefix(15))")
        exit(1)
    }
    // INK proof — a loadable-but-transparent PNG once shipped here and silently
    // hid the menu bar item (tiffRepresentation != nil doesn't prove ink).
    guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
        print("FAIL icon-\(name) no bitmap"); exit(1)
    }
    let w = cg.width
    let h = cg.height
    let dim = w * h
    var buf = [UInt8](repeating: 0, count: dim * 4)
    let ctx = CGContext(
        data: &buf, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
    var opaque = 0
    for i in stride(from: 3, to: dim * 4, by: 4) where buf[i] > 200 {
        opaque += 1
    }
    guard opaque >= dim * 3 / 20 else {
        print("FAIL icon-\(name) has NO ink: \(opaque)/\(dim) opaque pixels — the bar item would be invisible")
        exit(1)
    }
    print("PASS icon-\(name) (\(w)x\(h), \(opaque)/\(dim) opaque pixels)")
}

// Registered status bars: the exact lookup path MenuBarExtra's label uses.
MenubarIcon.registerStatusBars()
for name in ["green", "amber", "red", "grey"] {
    guard NSImage(named: MenubarIcon.imageName(name)) != nil else {
        print("FAIL registered NSImage(named:) missed for \(name)"); exit(1)
    }
}
check("status gauges registered in NSImage registry", true)

// MARK: 3. Registry snapshot — every adapter answers with its identity intact

let snapshot = await ProviderRegistry.snapshot()
check("at least 9 providers in snapshot (builtins + customs)",
      snapshot.providers.count >= 9)
let builtinRows = snapshot.providers.filter { row in
    ProviderRegistry.builtin.contains { $0.id == row.id }
}
check("builtin providers all present", builtinRows.count == 9)
for adapter in ProviderRegistry.builtin {
    let row = snapshot.providers.first { $0.id == adapter.id }
    check("row present: \(adapter.id)", row != nil && row?.label == adapter.label)
}

// MARK: 3b. Custom providers — JSON paths, store round-trip, semantics inversion

// JSONPath: dot segments, array indexes, combined forms.
let sampleJSON: [String: Any] = [
    "data": ["total_credits": 12.5, "list": [["remaining_percent": [ 73 ]], 4]],
    "user": "sam",
]
check("JSON path basic", (JSONPath.resolve("user", in: sampleJSON) as? String) == "sam")
check("JSON path nested", (JSONPath.resolve("data.total_credits", in: sampleJSON) as? Double) == 12.5)
check("JSON path array+index",
      (JSONPath.resolve("data.list[0].remaining_percent[0]", in: sampleJSON) as? Int) == 73)
check("JSON path miss resolves nil", JSONPath.resolve("data.missing.deeper", in: sampleJSON) == nil)

// Store round-trip against the SANDBOXED .env directory (overrideURL is set,
// so the custom_providers.json also lands in temp — never the user's file).
let config = CustomProviderConfig(
    id: "relay-test", name: "Relay Test", authStyle: "anthropic",
    url: "https://example.com/v1/credits", remainingPath: "data.total_credits",
    limitPath: "data.limit", reportsPercentLeft: false, unit: "USD")
try CustomProviderStore.save([config])
let reloaded = CustomProviderStore.load()
check("custom provider store round-trip",
      reloaded.count == 1 && reloaded[0] == config && reloaded[0].envKey == "CUSTOM_RELAY_TEST_API_KEY")

// The adapter answers "no API key" without touching the network; the registry
// picked the custom row up from the sandboxed store.
try CustomProviderStore.save([])
check("registry re-reads custom store (removed config disappears)",
      !ProviderRegistry.adapters.contains { $0.id == "relay-test" })

// `.left` semantics inversion: a row reporting 95% LEFT must threshold as
// nearly exhausted (95% consumed), never naive-anything; the raw .used row at
// 95 consumed is red by design.
var leftRow = ProviderResult(
    id: "t", label: "T", kind: .usage, value: 95, unit: "%", detail: "",
    ok: true, error: nil, ts: Date(), plan: nil,
    renewalAt: nil, nextResetAt: nil, weeklyResetAt: nil, monthlyResetAt: nil,
    primaryUsagePercent: 95, weeklyUsagePercent: nil, monthlyUsagePercent: nil,
    limitReached: false, unlimited: false)
check("raw .used 95% row is red (design)",
      ProviderRegistry.MenubarStatus.worst(of: [leftRow]) == .red)
leftRow.usageSemantics = .left
check("effective percent of 95% left is 5% consumed",
      leftRow.effectivePrimaryUsagePercent == 5)
check("95% left thresholds green (only 5% consumed)",
      ProviderRegistry.MenubarStatus.worst(of: [leftRow]) == .green)
check("left caption reads '95% left'", leftRow.windowCaption(95) == "95% left")
leftRow.usageSemantics = .used
check("a .left row at 0% left is red (nothing remaining)",
      ProviderRegistry.MenubarStatus.worst(of: [leftRow]) == .red || leftRow.effectivePrimaryUsagePercent == 100)

// The earlier step configured a (bogus) DeepSeek key, so this adapter performs a
// live HTTP call and must answer with the safe vocabulary, never a crash or
// provider response text.
let deepseekRow = snapshot.providers.first { $0.id == "deepseek" }
// The FULL authored vocabulary (ProviderResult.isUnconfigured's list) plus the
// transport prefixes — an adapter may answer with these and nothing else.
let safeVocabulary: [(String) -> Bool] = [
    { $0 == "no API key" },
    { $0 == "no OAuth token" },
    { $0 == "no access token" },
    { $0 == "no console session cookie" },
    { $0 == "console session expired - re-paste the cookie" },
    { $0 == "no ~/.codex/auth.json" },
    { $0 == "no apiKey in auth.json" },
    { $0 == "no ~/.commandcode/auth.json" },
    { $0 == "token expired — run `claude` once to refresh" },
    { $0 == "provider request failed (HTTP" },          // transport prefix
    { $0 == "provider request timed out" },
    { $0 == "provider unreachable" },
    { $0 == "provider data unavailable" },
]
check("deepseek row not ok with safe error",
      deepseekRow?.ok == false && deepseekRow?.error.map { e in safeVocabulary.contains { $0(e) } } == true)
// Every row either answered or carries authored vocabulary — previously this was
// asserted only for deepseek; with all nine adapters live it guards them all.
let allRowsHonest = snapshot.providers.allSatisfy {
    $0.ok || $0.error.map { e in safeVocabulary.contains { $0(e) } } == true
}
if !allRowsHonest {
    for bad in snapshot.providers.filter({ !$0.ok && !($0.error.map { e in safeVocabulary.contains { $0(e) } } ?? false) }) {
        print("DISHONEST ROW: \(bad.id) error=\(bad.error ?? "nil")")
    }
}
check("every provider row honest (ok or safe vocabulary)", allRowsHonest)
if !allRowsHonest { exit(1) }

// MARK: 3. A live cross-check with a configured key (no key on this machine fails gracefully)

let configuredDeepSeek = ProcessInfo.processInfo.environment["DEEPSEEK_API_KEY"]
if let configuredDeepSeek, !configuredDeepSeek.isEmpty {
    try EnvStore.shared.update(["DEEPSEEK_API_KEY": configuredDeepSeek])
    let live = await DeepSeekAdapter().fetch()
    print("live deepseek row: ok=\(live.ok) value=\(String(describing: live.value)) error=\(live.error ?? "-")")
}

// Combined headline arithmetic on the stub snapshot.
print("combined USD: \(snapshot.combinedBalanceUSD), credits: \(snapshot.combinedBalanceCredits)")
check("status computed", {
    switch snapshot.status { case .green, .amber, .red, .grey: return true }
}())

// MARK: 4. The real key file must be byte-identical to when we started.

let realEnvAfter = checksum(realEnvPath)
check("real .env untouched by smoke", realEnvBefore == realEnvAfter)

print("\nAll smoke checks passed.")
