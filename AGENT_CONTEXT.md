# Claude Usage — Agent Context Reference

Orientation for an AI coding agent (or a new human contributor) asked to open,
understand, or modify this project. Read this before editing.

A small floating **desktop widget** for macOS that shows live **Claude Code**
plan usage (5-hour session limit + weekly limit + extra credits), matched in size
and shape to the system desktop widgets. Built natively in Swift (SwiftUI +
AppKit), **no Xcode project** — compiled with `swiftc` via `build.sh`, ad-hoc
signed. It is a sibling of the "Vitals" system-metrics widget and shares the same
window shell.

## Layout of this repo

- **Source:** `Sources/ClaudeUsage.swift` — the entire app (usage model + SwiftUI views + window glue + entry point). No bridging header (unlike Vitals; no private C API needed).
- **Build:**  `build.sh` — `swiftc` invocation + `Info.plist` + ad-hoc codesign
- **App:**    `Claude Usage.app` — produced by `build.sh` (git-ignored; build it yourself)
- **Bundle ID / LaunchAgent label:** `com.claudeusagewidget.mac` (in both `build.sh` and `ClaudeUsage.swift`)

Everything is one Swift file. No package manifest, no dependencies, no test target.

## Data source (the important part)

- **Endpoint:** `GET https://api.anthropic.com/api/oauth/usage` — the same
  endpoint Claude Code's `/usage` screen uses. Headers:
  - `Authorization: Bearer <accessToken>`
  - `anthropic-beta: oauth-2025-04-20`
  - `Content-Type: application/json`
- **Response shape** (see `UsageResponse` / `LimitBucket` / `ExtraUsage`):
  - `five_hour`, `seven_day`, `seven_day_opus`, `seven_day_sonnet` — each a
    `{ utilization: 0–100, resets_at: ISO8601-with-fractional-seconds }`.
  - `extra_usage` — `{ is_enabled, monthly_limit (USD), used_credits (USD) }`.
- **Token read** (`Usage.readToken`): spawns
  `/usr/bin/security find-generic-password -s "Claude Code-credentials" -w`,
  parses the JSON, and pulls `claudeAiOauth.accessToken`.
  - **Why `security` and not `SecItemCopyMatching`:** the `security` binary is
    already on the Keychain item's ACL, so re-signing the app on every rebuild
    (ad-hoc) never re-triggers a Keychain permission prompt. Keep it this way.
  - The token is re-read **every poll** (60 s) so Claude Code's own token
    rotation is picked up automatically.
- **Errors** (`FetchError`): `noToken`, `http(401/403)` → "Sign-in expired — use
  Claude Code once to refresh", other HTTP, network, parse. On any error the UI
  keeps the last good numbers and surfaces the message in the footer / detail.

There is **no refresh-token flow** — on 401 the fix is "run Claude Code once."
There are **no secrets in the repo**; the app only ever reads the user's own
local token at runtime.

## UI structure

- `Usage: ObservableObject` — model. Two timers in `init`: a 60 s `pollTimer`
  (calls `fetch()` on a background queue) and a 1 s `tickTimer` (updates `now` so
  countdowns stay live). `fetchUsage()` runs the request synchronously on a
  background queue via a `DispatchSemaphore`.
- `WidgetView` — two `LimitRing`s (SESSION / WEEK), an optional `BarMetric`
  (EXTRA, only when `extraEnabled && extraLimit > 0`), a status footer, and an
  expandable `DetailView`.
- Formatting helpers: `fmtCountdown`, `fmtResetTime`, `fmtUSD`, `fmtAgo`.
- Color: `Threshold.color(v, warn: 0.70, crit: 0.90)` → green / amber / red.

## Window / sizing (matches macOS desktop widgets)

- Borderless, non-activating `NSPanel` at **`.normal`** level (other windows can
  cover it), `canJoinAllSpaces` + `.stationary` + `.fullScreenNone`,
  `LSUIElement` (no Dock icon).
- **`.fullScreenNone` is load-bearing** — without it a non-activating
  all-Spaces panel also floats over other apps' full-screen Spaces.
- **180×180 pt** window, **8 pt** margin (→ 164 pt visible panel), **24 pt**
  corner radius — same footprint as macOS small desktop widgets. Constants at the
  top of `WidgetView`: `windowSize`, `panelMargin`, `panelRadius`.
- Position persists via `setFrameAutosaveName("ClaudeUsageWidgetFrame")`. Default
  spot stacks just below where the Vitals widget defaults (top-right, −190 pt).
- **Placement guidance for users:** it's a normal-level desktop panel, so it
  covers any desktop file icons under it. It's meant to be parked on top of an
  existing macOS system desktop widget, where macOS already keeps icons clear.
  (This is the headline instruction in the README.)

## Lifecycle / auto-start

- Auto-starts at login via a per-user **LaunchAgent** (reliable for ad-hoc-signed
  apps, unlike `SMAppService`). Enabled on first run (guard: `UserDefaults` key
  `ClaudeUsageDidConfigureLogin`); toggle via right-click → Launch at Login.
- LaunchAgent path: `~/Library/LaunchAgents/com.claudeusagewidget.mac.plist`
  (`RunAtLoad`, `ProgramArguments` → the app's executable path). Records the app's
  current path — if the app is moved, toggle Launch at Login off/on to refresh it.

## Build / run / debug commands

```bash
# Build (from the repo root)
./build.sh                    # produces "Claude Usage.app", ad-hoc signed
open "Claude Usage.app"

# Rebuild after edits
pkill -f "Claude Usage.app/Contents/MacOS/ClaudeUsage" 2>/dev/null; ./build.sh; open "Claude Usage.app"

# Is it running?
pgrep -lf "ClaudeUsage"

# Sanity-check the endpoint by hand (uses your real token — treat output as secret)
TOKEN=$(security find-generic-password -s "Claude Code-credentials" -w | python3 -c 'import sys,json;print(json.load(sys.stdin)["claudeAiOauth"]["accessToken"])')
curl -s https://api.anthropic.com/api/oauth/usage -H "Authorization: Bearer $TOKEN" -H "anthropic-beta: oauth-2025-04-20" | python3 -m json.tool
```

`build.sh` compiles with `swiftc -parse-as-library -swift-version 5 -O
-framework AppKit -framework SwiftUI`, then ad-hoc codesigns.

## Gotchas (don't "fix" these)

- **SourceKit false positive:** an editor/LSP will flag the `@main` attribute as
  "cannot be used in a module that contains top-level code." That's a false
  positive from analyzing the file without `-parse-as-library`; `build.sh`
  compiles cleanly. Don't restructure to appease the editor.
- **Keep the `security` shell-out** for the token (see above) — switching to the
  Security framework re-introduces Keychain prompts on every ad-hoc rebuild.
- **Ad-hoc signature** — no paid Developer ID, so Gatekeeper quarantine-warns on
  first open, and the Keychain may prompt once on first token read. Both expected.
- The endpoint, headers, and JSON shape are **undocumented / unofficial** and may
  change; treat a parse failure or new HTTP status as "Anthropic changed it,"
  not as a bug in the widget.
- This is an **unofficial** widget, not affiliated with Anthropic. Keep that
  framing in any user-facing text you add.
