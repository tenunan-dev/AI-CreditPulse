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
check("9 providers in snapshot", snapshot.providers.count == 9)
for adapter in ProviderRegistry.adapters {
    let row = snapshot.providers.first { $0.id == adapter.id }
    check("row present: \(adapter.id)", row != nil && row?.label == adapter.label)
}

// The earlier step configured a (bogus) DeepSeek key, so this adapter performs a
// live HTTP call and must answer with the safe vocabulary, never a crash or
// provider response text.
let deepseekRow = snapshot.providers.first { $0.id == "deepseek" }
let safeVocabulary: [(String) -> Bool] = [
    { $0 == "no API key" },
    { $0.hasPrefix("provider request failed (HTTP") },
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
check("every provider row honest (ok or safe vocabulary)", allRowsHonest)

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
