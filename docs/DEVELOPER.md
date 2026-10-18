# AI CreditPulse — Developer Guide

Architecture, build system, test strategy, and the sharp edges we hit
(macOS 26/27 era) documented so the next person doesn't rediscover them.

## Product shape

Native macOS **menu bar agent** (no Dock icon):

- `NSStatusBar` status item (`StatusBarController.swift`) with a button whose
  `NSImage` is set **directly** (no name-resolution layer; gauges re-tint via a
  debounced `AppState.objectWillChange` sink).
- A transient `NSPopover` hosts the SwiftUI dropdown (`MenuBarContentView`).
- The main program window is AppKit-owned (`NSWindow` + `NSHostingView`) inside
  `AppDelegate` — `isReleasedWhenClosed = false`, cached and reusable, so
  closing it does not end the agent.
- `LSUIElement = true`, bundle id `com.faisal.aicreditpulse`, min macOS 14.

## Package layout (SPM, no Xcode project)

| Target | Role |
|---|---|
| `AICreditPulseCore` | data layer (library): provider registry, status model, 9 adapters, `.env` store, icon loader |
| `AICreditPulse` | app target: AppKit shell + SwiftUI surfaces |
| `AICreditPulseSmoke` | headless test harness (no GUI), runs against a **sandboxed `.env`** |

## Core design decisions

### Status model (ProviderRegistry / MenubarStatus)
- Monotonic `MenubarStatus` promote: green(0) < grey(1) < amber(2) < red(3).
  The gauge shows `worst(of: visible rows)` — idle-grey can never downgrade a red.
- `ProviderResult.isUnconfigured` matches the authored no-credential /
  expired-credential vocabulary; unconfigured rows read grey.
- Combined Σ (`combinedUSD`) sums **visible** rows only (ILMU's MYR wallet is
  excluded by design and shown as MYR).

### Adapters (Adapters+M2.swift)
Ported 1:1 from the Hermes Provider Usage Plugin (`backend/plugin_api.py`):

- **Claude** — OAuth usage from the official endpoints; credential ladder
  keychain → `~/.claude` files → `.env` token; HTTP 401 ⇒ "expired credential".
- **Codex** — wham/usage endpoint via `~/.codex/auth.json` (GO-plan semantics).
- **OpenCode** — key-cycling on 401/403 across multiple configured keys.
- **Z.ai** — plan quota windows + a **15-min-cached** PAYG probe that
  classifies code `1113` / "insufficient balance".
- **CommandCode** — three routes, one cache; derives a monthly gauge with a
  live-period guard.
- **Nous** — `.env` override → Hermes `auth.json` profile-first merge.
- **ILMU** — cookie auth, active-period grant + pack folding; explicit
  "cancelled / period ended" explanations; wallet in MYR (never merges USD).
- **OpenRouter / DeepSeek** — direct key-auth balance/credits probes.

Shared plumbing lives in `ProviderHTTP.swift` (typed get/post, per-provider
TTL cache with force-bypass, `sanitized`/`safe` logging, `ProviderFailure`).
**Safe vocabulary sanitizer** is applied centrally in
`ProviderResult.unavailable` (port of `_safe_reason`) — raw network error text
never reaches the user.

### EnvStore (EnvStore.swift)
- Path: `~/Library/Application Support/AI CreditPulse/.env` (auto-created 0600),
  watch via DispatchSourceFileSystemObject, mtime-gated hot reload,
  `.envStoreDidChange` notification for instant re-query.
- **Values are sanitized to a single line** on write (newlines collapse to a
  space). A pasted multi-line value once *split the file*, orphaned quote
  fragments, and made saved keys vanish — the sanitizer plus the rewrite's
  orphan-drop (`continuation lines whose name starts with a quote` are skipped)
  make that class of corruption impossible. Below all reads happen after `load()`
  rebuilds the dict.
- **Test sandboxing**: `EnvStore.overrideURL` (set by the smoke harness) points
  every operation at a temp file. The real key file is additionally checksummed
  before/after; a test run that so much as touched it fails. (History: an
  earlier smoke deleted the real file — never again.)

### MenubarIcon (MenubarIcon.swift)
- `resourcesBundle` resolves the SPM resource bundle **manually** — never
  `Bundle.module`, whose generated accessor is an **uncatchable fatalError**
  when the bundle is missing (this once crashed every launch of the installed
  app: `EXC_BREAKPOINT` in `NSBundle.module`).
- `loadVerified` explicitly sets `isTemplate = false` and an accessibility
  description, handles flattened / nested resource layouts, and returns nil on
  any miss (no crash path from the icon loader).
- `registerStatusBars()` also registers gauges into NSImage's named registry at
  18pt (kept from the MenuBarExtra era; harmless belt-and-braces).

### Icon pipeline (Scripts/gen_icons.swift)
Paints the 4 gauge PNGs **directly with CoreGraphics** (ring + sweep + center
dot) — no SF Symbols. Reason: an earlier masked-symbol generation produced
32×32 PNGs that were ~0% opaque; "loadable but invisible" images then defeated
MenuBarExtra *and* NSStatusBar alike. The smoke test now verifies real ink
(pixel alpha scan ≥ 15% coverage) — a transparent PNG cannot pass again.
If you regenerate icons: run `swiftc Scripts/gen_icons.swift` from the repo
root, then clear fileprovider xattrs (`xattr -c Sources/.../icon-*.png`).

## Build system (Scripts/build_app.sh)

`zsh` script; assembles a hand-rolled `.app`:

1. `swift build` — **scratch dir is forced outside the iCloud-synced tree**
   (`$TMPDIR/aicreditpulse-scratch`). Files inside `~/Documents` accumulate
   `com.apple.fileprovider.fpfs#P` / `FinderInfo` / `provenance` xattrs, which
   ad-hoc codesign rejects as "resource fork, Finder information, or similar
   detritus" — this blocked every build until scratch was moved out.
2. Bundle assembly: `Contents/MacOS`, generated `Info.plist`
   (`LSUIElement`, `CFBundleIconFile=AppIcon`, version 0.1.0),
   `AICreditPulse_AICreditPulseCore.bundle` copied **whole** into
   `Contents/Resources/` (required by the Core resource loader) + flattened
   icon PNGs as `Bundle.main` fallback, `AppIcon.icns` (assembled from
   `Assets/AppIcon.iconset`; `iconutil` is broken in the iCloud Documents
   sandbox — a python container-writer stands in).
3. `xattr -cr` on Resources + AppleDouble `._*` cleanup.
4. `codesign --force --deep --sign -` the app (ad-hoc).

Install target: `~/Applications/AI CreditPulse.app` (canonical on this machine).
After any rebuild: `pkill -f "AI CreditPulse"` before relaunching, or you get
two agents fighting over one status slot.

## Testing

`AICreditPulseSmoke` (~35 checks, `main.swift`):

1. `.env` round-trips — skeleton, permissions, rotation, quote values,
   **newline-paste sanitization**, orphan preservation.
2. Icon kit — load + **pixel-ink proof** + named-registry lookup.
3. Registry — 9 providers, safe-vocabulary honesty, worst-status math,
   visible-row combined rules.
4. Live cross-check when sandbox write is available (self-cleaned).
5. **Real `.env` integrity** — checksummed before/after; any difference fails.

Run: `.build/**/AICreditPulseSmoke` (the build script's scratch contains the
binary too). All checks print `PASS`/`FAIL` with exit code.

## macOS 26/27 (Tahoe-era) sharp edges

- **ControlCenter owns the bar**: third-party items are placed by StatusKit;
  there is a per-app allow list (System Settings → Control Center → Menu Bar
  Only) and known system bugs (items off-screen at `y=-17`, ghost slots).
  Documented escape hatches: `killall ControlCenter`, the allow toggle,
  menu managers. See the omlx#1497 / nextcloud#10575 threads.
- **MenuBarExtra was removed** as a liability: two independent label
  resolution paths failed to show *any* item for this app configuration; a raw
  `NSStatusItem` has zero ambiguity.
- Hover/mouse-movement inside status-item views changed across versions; we
  don't rely on hover for core functionality.

## Release flow

1. Bump `CFBundleVersion` / `CFBundleShortVersionString` in
   `Scripts/build_app.sh` and add a `CHANGELOG.md` entry.
2. `./Scripts/build_app.sh release`
3. Smoke the release binary.
4. `ditto -c -k --keepParent ".build/spm-app/AI CreditPulse.app" "dist/AI CreditPulse-<version>.zip"`
5. (On a GUI session only) DMG:
   `hdiutil create dist/AI CreditPulse-<version>.dmg -volname "AI CreditPulse" -srcfolder ".build/spm-app/AI CreditPulse.app" -ov -format UDZO`
6. Install to `~/Applications` and relaunch manually to confirm.

## Doc map

- `README.md` — overview + build basics;
- `docs/USER-GUIDE.md` — end-user manual;
- `docs/DEVELOPER.md` — this file;
- `CHANGELOG.md` — release history.
