# Changelog

All notable changes to **AI CreditPulse** are documented here.
Format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/);
versioning is [SemVer](https://semver.org/) (pre-1.0, so 0.x is allowed to
break).

## [0.1.0] — 2026-10-19

First end-to-end release of the menu bar agent.

### Added
- Menu bar gauge (green / amber / red / grey) reflecting the worst status of
  the user's *visible* providers; grey = unconfigured idle.
- Dropdown with combined USD Σ, per-provider rows (plan badge, usage bars,
  safe status copy), show/hide ticks per row, and footer actions
  (Refresh now / Open AI CreditPulse / Quit).
- Main program window: live rows, API-key form with instant save + verified
  per-field ✓ indicator + "N of 8 keys set" counter, General section
  (refresh interval, Launch at login, pop-up-at-launch, stay-hidden-on-restart).
- All 9 provider adapters ported 1:1 from the Hermes Provider Usage Plugin:
  Claude (OAuth + credential ladder), Codex (GO plan), OpenRouter, DeepSeek,
  Z.ai/GLM (quota windows + cached PAYG probe), OpenCode (key cycling),
  CommandCode (three routes, one cache), Nous (profile-first merge), ILMU
  (MYR wallet, pack folding).
- `.env` key store (`~/Library/Application Support/AI CreditPulse/.env`,
  mode 600) with hot reload and change notifications.
- AppKit status item + popover shell with LSUIElement packaging, ad-hoc
  signing, and app icon/brand assets.
- Headless smoke suite (~35 checks) with a **sandboxed** `.env` and a real-
  file checksum guard.
- Project docs: `README.md`, `docs/USER-GUIDE.md`, `docs/DEVELOPER.md`.

### Fixed
- **Invisible menu bar item** (the saga): the shipped gauge PNGs contained
  zero opaque pixels (32×32, 178 bytes, fully transparent). Replaced with
  CoreGraphics-painted 64×64 gauges (ring + sweep + pulse dot, 33% ink), and
  the smoke test now verifies actual pixel ink, so "loadable but empty" images
  can never pass again.
- **Launch crash of installed builds**: `MenubarIcon` resolved icons through
  `Bundle.module`, whose accessor aborts the process (uncatchable fatalError)
  when the SPM resource bundle is absent — the generated `.app` had never
  carried it. Icons now resolve via a manual bundle locator with Bundle.main
  fallback; the build script ships the resource bundle whole.
- **Saved keys disappearing**: multi-line pastes wrapped the one-line
  `KEY=VALUE` format, splitting the file into orphan quote fragments; every
  rewrite then preserved the junk and could eat unlisted keys. Values are now
  sanitized to single lines and orphan fragments are dropped on rewrite.
- **Smoke test destroying user data**: the smoke harness once ran on the real
  shared `.env` path (and deleted it). Tests are now carved into a temp file
  and checksum-verified against the user's file.
- **Builds failing to codesign**: iCloud fileprovider xattrs
  (`fpfs#P`, `FinderInfo`, `provenance`) on freshly written resources inside
  the synced `~/Documents` tree triggered codesign "detritus" errors; the
  build scratch lives outside the synced tree, and Resources get xattr-scraped
  before bundling.
- **Ghost status item on macOS 26/27**: replaced `MenuBarExtra` (whose label
  image never resolved in this stack) with a raw `NSStatusItem` whose
  `NSImage` is set directly and re-tinted on state changes.

### Security / Privacy
- Keys stay in one local mode-600 file; no telemetry; the app talks only to
  the providers' own APIs.

[0.1.0]: ./README.md
