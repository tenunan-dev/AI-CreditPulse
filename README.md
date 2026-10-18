# AI CreditPulse

A native macOS menu bar agent that shows **how much AI credit you have left** —
plan allowance and pay-as-you-go balance — across 9 providers, at a glance.

You get a colored gauge in the menu bar (green → amber → red) that reflects the
worst status of the providers you've chosen to watch. Click it for the full
picture: combined balance, one row per provider with usage bars and plain-
language status ("unconfigured", "expired session", "limit reached", …).

## Providers

| Provider | Credentials used | Notes |
|---|---|---|
| Claude Code | OAuth token (keychain / `~/.claude` / `.env`) | 5h window + weekly usage |
| Codex (ChatGPT) | `~/.codex/auth.json` (local CLI login) | wham/usage of GO plan etc. |
| OpenRouter | `OPENROUTER_API_KEY` | plan + PAYG, credits |
| DeepSeek | `DEEPSEEK_API_KEY` | PAYG balance (USD) |
| Z.ai / GLM Coding | `GLM_API_KEY` (aliases: `ZAI_API_KEY`, `ZHIPU_API_KEY`) | plan windows + PAYG balance |
| OpenCode | `OPENCODE_API_KEY` (multiple cycleable keys) | plan + PAYG |
| CommandCode | local CLI auth (`~/.cmcmd*`) | derived monthly gauge + live period |
| Nous Portal | `NOUS_PORTAL_TOKEN`, or Hermes `auth.json` profile merge | plan + PAYG |
| ILMU (MYR) | `ILMU_CONSOLE_COOKIE` (or `HERMES_CUSTOM_ILMU_COOKIE`) | MYR wallet — shown as MYR, never converted/merged into USD Σ |

Combined headline sums **USD balances of your visible providers**; ILMU's MYR
wallet is shown separately by design.

## Menu bar

- **Gauge icon**: green < 60% used · amber ≥ 60% · red ≥ 90% / depleted / real error.
  Unconfigured providers (no key yet) read grey "idle" and never make the icon red.
- **Dropdown**: combined USD Σ, one row per provider (usage bars, window badges,
  error copy). Footer: Refresh now · Open AI CreditPulse · Quit.
- Rows have **show/hide ticks** — hidden rows don't count toward the Σ or the
  gauge. Visibility is remembered.

## Main window

Open from the dropdown ("Open AI CreditPulse") or by launching the app.

- Live status rows (same data as the dropdown, with ticks)
- **API keys** form: paste a key, press Enter (instantly saved) or use
  *Save to .env*. Fields show a green ✓ when a value is stored. Keys are
  validated by reading the file back — the counter under the form is the truth
  of the file, not of the fields.
- **General**: refresh interval (default 2 min), Launch at login,
  "Pop up this window at launch", "Stay hidden when macOS auto-launches at
  restart" (after a restart the gauge goes straight to the menu bar, silently).
- **Quit** ends the whole agent; closing the window does not.

## Key storage

Keys live in one file, owned only by this user:

```
~/Library/Application Support/AI CreditPulse/.env       (mode 600)
```

- The Settings form writes it; editing by hand works too (`KEY=VALUE` lines).
- Long values **must not span lines**; quotes are optional, e.g.
  `OPENROUTER_API_KEY=sk-or-v1-…`.
- Changes hot-reload — no restart needed.
- Nothing is uploaded. The file stays on this machine; the app talks to each
  provider's own API with your keys.

## Build from source

```bash
git clone <this repo>
cd AI-Credit-Tracker
./Scripts/build_app.sh release        # → AI CreditPulse.app (ad-hoc signed)
open .build/spm-app/AI\ CreditPulse.app
```

- Swift 6 toolchain (Xcode 16+), macOS 14+ deployment, arm64/x86_64.
- The build assembles a proper `.app` from the SPM executable, embeds the icon
  resources, and ad-hoc signs it. The build scratch lives outside the iCloud-
  synced tree on purpose (fileprovider xattrs break ad-hoc codesign).
- Headless checks: `.build/**/AICreditPulseSmoke` runs ~35 assertions and is
  **sandboxed** to a temp `.env` — it can never touch your real keys, and it
  checksums your real key file to prove it.

## Distribution

`dist/AICreditPulse-<version>.zip` contains the built app. Unzip, drag to
`/Applications` or `~/Applications`, launch once (see launch options) and
paste your keys in the main window.

First launch may trip Gatekeeper because the build is ad-hoc signed (no
developer ID): right-click → Open → Open, or
`xattr -dr com.apple.quarantine /Applications/AI\ CreditPulse.app`
if you download the zip.

## Troubleshooting

- **No icon in the menu bar** — on macOS 26/27 (Tahoe-era), third-party menu
  items are managed by ControlCenter: System Settings → Control Center →
  "Menu Bar Only" list → enable AI CreditPulse. If it's enabled but ghosted,
  `killall ControlCenter` once re-places stale items. (Menu managers like
  Bartender/Ice can also hide items.)
- **A row says "unconfigured"** — that provider has no usable credential yet;
  add it in the main window or tick it off (show/hide) if you don't use it.
- **ILMU keeps saying "session expired"** — it needs the `ilmu_session`
  **cookie** from the console (browser devtools → cookies), not the `sk-…`
  API key.
- **Saved key "doesn't show"** — press Enter in the field or click *Save to
  .env*; the ✓ dot and "N of 8 keys set" counter confirm the file write. An
  older bug could corrupt this file with multi-line pastes; current builds
  sanitize values (and return a green "Saved ✓" notice after each save).
- **After an app rebuild** — make sure the old instance isn't still running:
  `pkill -f "AI CreditPulse"` before relaunching.

## Project layout

- `Sources/AICreditPulseCore/` — data layer: provider registry, status model,
  9 network API adapters (AI CreditPulse ports of the Hermes Provider Usage
  Plugin), .env store, guard-free status math.
- `Sources/AICreditPulse/` — AppKit + SwiftUI front end: status item +
  popover, main window, brand assets.
- `Sources/AICreditPulseSmoke/` — headless smoke test.
- `Scripts/build_app.sh` — app bundling; `Scripts/gen_icons.swift` — the
  status gauges; `Scripts/make_icon.swift` — the app icon/logo.
- `dist/` — distributable zip (DMG from a GUI session).

## Documentation map

- `README.md` — overview & build basics (this file)
- [`docs/USER-GUIDE.md`](docs/USER-GUIDE.md) — end-user manual (keys, menus,
  troubleshooting)
- [`docs/DEVELOPER.md`](docs/DEVELOPER.md) — architecture, build system,
  test strategy, macOS 26/27 sharp edges
- [`CHANGELOG.md`](CHANGELOG.md) — release history

Version 0.1.0 · built with SPM, no Xcode project required.
