# AI CreditPulse — User Guide

Everything you need to run AI CreditPulse day to day. For the quick pitch and
the visual overview, start with the top-level `README.md`.

## 1. First launch

1. Unzip `dist/AI CreditPulse-<version>.zip` and drag **AI CreditPulse.app**
   into `/Applications` (or `~/Applications`).
2. Right-click the app → **Open → Open** (it is ad-hoc signed; calendar of
   Gatekeeper's one-time warning). Alternatively:
   ```bash
   xattr -dr com.apple.quarantine /Applications/AI\ CreditPulse.app
   ```
3. The app starts as a **menu bar agent**:
   - the main window greets you (should you close it, nothing breaks — see §4),
   - the menu bar shows the status **gauge** — grey until at least one provider
     is configured, then green/amber/red.

## 2. Adding your keys

Open the main window (dropdown → **Open AI CreditPulse**, or relaunch):

1. In the **API keys** section, paste the credential for each provider you use.
   Which credential?
   - Most providers take an **API key** from their dashboard (each field has a
     *Get key* link).
   - **Claude Code** and **Codex** discover their credentials automatically
     from the local CLIs (`claude`/`codex` logins); you usually don't fill them.
   - **CommandCode** reads its local CLI auth automatically too.
   - **ILMU** needs the `ilmu_session` **cookie** (browser devtools →
     Application → Cookies → copy the value). The `sk-…` API key is NOT a cookie.
2. Press **Enter** in a field, or click **Save to .env**.
   - The field's dot turns ✓ green once the value is verified **in the file**,
   - the counter updates: *Saved ✓ — N of 8 keys set*.
3. Rows re-query immediately; the dropdown reflects new data within a second.

All 8 supported `.env` slot names:

| Slots | Used by |
|---|---|
| `OPENROUTER_API_KEY` | OpenRouter |
| `DEEPSEEK_API_KEY` | DeepSeek |
| `GLM_API_KEY` | Z.ai/GLM Coding (aliases: `ZAI_API_KEY`, `ZHIPU_API_KEY`) |
| `OPENCODE_API_KEY` | OpenCode (multiple values cycleable) |
| `NOUS_PORTAL_TOKEN` | Nous Portal |
| `ILMU_CONSOLE_COOKIE`, `HERMES_CUSTOM_ILMU_COOKIE` | ILMU console |
| `CLAUDE_CODE_OAUTH_TOKEN` | optional Claude override (keychain/CLI are tried first) |

## 3. Reading the dropdown

- **Headline**: combined Σ of your *visible* providers' USD balances
  (pay-as-you-go + plan credits). ILMU's wallet is measured in **MYR** and is
  deliberately never merged into this Σ.
- **Rows**: provider name, status headline, plan badge, window bars
  (e.g. Claude's 5-hour/weekly windows), and one-line status copy.
- **Status vocabulary**:
  - *no API key* / *no console session cookie* → unconfigured (grey, won't
    redden the gauge),
  - *session expired / re-auth* → the stored credential is stale,
  - *limit reached* / *depleted paid balance* → red, act now,
  - *unavailable* → the provider itself had a hiccup; we show a safe error.
- **Ticks**: show/hide per row. Hidden providers are excluded from the Σ and
  the gauge color, and this is remembered across relaunches.

## 4. The main window

- Closing it **never** quits the agent — the gauge keeps watching.
- **Footer buttons**: *Refresh* (force a re-query now) and *Quit* (only Quit
  ends the process).
- **General** section:
  - **Refresh every** — polling interval (default 2 min),
  - **Launch at login** — registers the menu bar agent at boot,
  - **Pop up this window at launch** — default ON for manual launches,
  - **Stay hidden when macOS auto-launches at restart** — when ON, a launch
    that comes from the login item right after a reboot shows only the gauge,
    silently.

## 5. Where your data lives

- Keys: `~/Library/Application Support/AI CreditPulse/.env` (mode 600, local
  only, hot-reloaded on edit; hand-editing is fine).
- Preferences (visibility ticks, launch options, interval): standard
  `UserDefaults` for the app.

Rules of thumb: never let a value span multiple lines; quotes optional. If you
hand-edit, keep the `KEY=VALUE=` shape — the app repairs orphan fragments on
its next save.

## 6. Refresh behavior

- List changes: every *Refresh every* minutes, when you open the dropdown, and
  whenever `.env` changes.
- *Refresh now* / *Save to .env* force past the short cache — handy right
  after rotating a key.
- A failing provider is re-tried on the next cycle; cached errors expire like
  cached data (a couple of minutes), so a fixed network doesn't stay sticky.

## 7. Troubleshooting

| Symptom | What to do |
|---|---|
| Menu bar item invisible / ghost | System Settings → Control Center → **Menu Bar Only** list → enable "AI CreditPulse"; or `killall ControlCenter`. If Bartender/Ice run, check their hidden list. |
| App "is running" but no icon after an upgrade | `pkill -f "AI CreditPulse"`, then relaunch. |
| A row stays "unconfigured" | Add the key in the main window (✓ green dot), check for stray whitespace, use the right alias (e.g. `GLM_API_KEY`). |
| ILMU row says "session expired" | Paste the fresh `ilmu_session` **cookie**, not the `sk-` API key. |
| Codex/Claude rows wrong | Verify the local CLIs are logged in (`claude`, `codex`); they read auth from those stores. |
| Old saved keys vanished | Older version's smoke test, past-mangled `.env` — current builds sanitize values and never touch your file from tests (checksummed). |
| Want a clean start | Quit the app, delete `~/Library/Application Support/AI CreditPulse/.env`, relaunch (fresh skeleton is written for you). |

## 8. Privacy

The app talks **only** to the providers' own APIs with your credentials, from
your machine. No telemetry, no middle server, no analytics.
