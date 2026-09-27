# Netra (नेत्र — "the eye")

macOS menu-bar app: a glanceable view of coding-agent token usage and estimated
cost across Claude Code, Codex, OpenCode, Gemini CLI, Copilot CLI, Pi, and
every other agent ccusage detects — plus provider limits and agent-aware
keep-awake.

**Requires:** Apple Silicon Mac, macOS 14 (Sonoma) or newer.

## Install (Homebrew)

```sh
brew tap sahabji0P/tap
brew trust sahabji0p/tap        # Homebrew 6+ asks once per third-party tap
brew install --cask netra
xattr -dr com.apple.quarantine /Applications/Netra.app   # until the app is notarized
open -a Netra
```

Run the `xattr` line **before** the first launch — the app isn't notarized
yet, so macOS quarantines it on download. If a "Netra is damaged" dialog ever
appears, click **Cancel**, never "Move to Trash".

Look for the eye icon in your menu bar. Netra reads your local agent session
logs (`~/.claude`, `~/.codex`, …), so stats appear once you've run an agent at
least once on this machine. Click the usage summary or **Open Usage** for the
full dashboard; **Settings** opens in that same window.

The popover leads with your **subscription limits** — one card per provider
with each window's bar, how much is used, when it resets, and (optionally) a
pace line that warns when you'd run out before the reset. Below that is the
period's API-equivalent cost and activity chart, then a single row of actions
(Keep Awake, dashboard, Settings, refresh, Lock & Sleep, quit).

Hover a provider's subscription card in the popover (Claude, Codex, Cursor)
and a side panel slides out beside it with that provider's cost for today,
this week, and this month, its token mix, and a per-model split (tokens and
cost) for the selected period; it hides when the pointer leaves. Clicking the
card toggles it.

The dashboard window has two overview pages and five settings pages in its
sidebar. **Usage** shows headline numbers with the change against the previous
equal period and sparklines, the stacked activity chart, a provider donut
(hover a provider for its models), token composition, and a model/day table
you can filter by provider. **Subscriptions** shows every provider's limit
windows, pace, and provider-specific detail (Cursor's billing cycle per model,
Codex reset credits). Both always cover **every** provider found in your logs.
Settings are grouped into **Menu Bar & Popover**, **Limits**, **Providers**,
**Notifications**, and **General**. The menu-bar popover is the curated view:
**Providers** lets you toggle which providers appear there (hidden providers
are removed from the popover's totals too, so its numbers stay consistent).

**Limits** personalizes the limit cards, with a live preview: bars that show
used or remaining, countdown or date-and-time resets, the pace line, and the
order of provider cards. **Menu Bar & Popover** picks the menu-bar label —
including a **Limit bars** icon: two small bars (short window and the
most-used longer window) for whichever provider is closest to a limit, with a
dot while Keep Awake is on — which popover sections show, and the period the
popover opens on.

**Claude** and **Codex** limits appear whenever a limit source is available.
If Claude was used this week but no limit source is available (Claude Code
hasn't cached limits on that Mac — older versions and API-key sign-ins don't
— or its cache is stale), the popover shows a Claude card saying why, with a
one-click **Use live limits from Anthropic** button. Netra looks for Claude
Code's cache in `$CLAUDE_CONFIG_DIR/.claude.json`, `~/.claude.json`, and
`~/.claude/.claude.json`, using the freshest.
Codex limits are live: Netra asks the Codex CLI's own app server
(`codex app-server`, `account/rateLimits/read`) — the CLI handles its login
and asks OpenAI directly, so the numbers are current even when no Codex
session ran recently (session logs go stale across resets, including redeemed
reset credits). Banked resets — Codex's free "Full reset (Weekly + 5 hr)"
credits — are shown with their count and next expiry in the popover, and
each one's expiry on the Subscriptions page. Claude has no banked resets;
its card shows the status of your extra-usage credits instead (on with
spend vs cap, off, or used up). If
the CLI isn't installed or doesn't answer, Netra falls back to the newest
`rate_limits` snapshot in `~/.codex/sessions`. **Cursor** is opt-in. Turn on **Cursor usage** in Settings and
Netra uses the login Cursor already saved on this Mac to read, from Cursor's
own dashboard API:

- Limits: included / API / Auto / on-demand / Grok Bot windows (checked at
  most every 5 minutes).
- Per-request usage history (`get-filtered-usage-events`) — every Cursor
  surface (editor, CLI, background agents, Grok Bot) on every machine. It is
  backfilled once for the same 190-day window as the other providers, then
  synced incrementally every 15 minutes, and kept in
  `~/Library/Application Support/Netra/cursor-events.json`. Each request's
  cost is Cursor's own API-rate price for it, the same basis as the estimates
  for other agents, so Cursor sits in the day / week / month totals and charts.
- The current cycle's tokens per model. The cycle dollar figure is usage
  priced at API rates — what your plan's included and bonus usage covers —
  not what you are billed; actual extra billing is the on-demand amount. That
  cycle figure excludes Grok Bot, which has its own weekly allowance.

The login is sent only to cursor.com; those dashboard endpoints are
undocumented and can change without notice. A rejected login backs off for
six hours; a failed sync keeps the last history. Turning the setting off
means Netra reads nothing from Cursor.

Subscriptions: Codex limits are provider-reported from local rollout data. Claude
limits are Anthropic's real percentages, read from the response Claude Code
itself caches in `~/.claude.json` — including the model-scoped weekly bucket
and your plan tier, with no Keychain access and no network. Turn on **Live
Claude limits** in Settings to fetch fresh numbers directly from Anthropic on
every refresh using the sign-in Claude Code already keeps in the Keychain.
macOS asks only when you turn it on or click **Allow Keychain access** (choose
"Always Allow"); background refreshes read silently and never show the
password dialog. The token is kept in memory only and is only ever sent to
api.anthropic.com. Only when neither source is available does Claude fall
back to a clearly-labelled local estimate (current 5-hour block versus your
own heaviest recent block).

Settings also controls the menu-bar label, which sections appear in the
popover, and optional daily-token or usage-indicator alerts. macOS
notification permission is requested only after an alert is enabled.
Equivalent API cost is an estimate, not subscription spend.

**Lock & Sleep** locks the screen immediately and puts the Mac to sleep.
**Keep awake** blocks idle sleep only — the display still sleeps, and closing
the lid still sleeps the Mac.

## Upgrade

```sh
brew update                      # refreshes the tap — required, upgrade won't see new versions without it
brew upgrade --cask netra
xattr -dr com.apple.quarantine /Applications/Netra.app
```

The app shows a quiet notice in its footer when a newer release exists.

## Troubleshooting

- **Brew keeps seeing an old version** → stale tap clone; re-clone it:
  `brew untap --force sahabji0p/tap && brew tap sahabji0P/tap && brew trust sahabji0p/tap && brew install --cask netra`
- **"App source '/Applications/Netra.app' is not there" during upgrade** → the
  app was deleted while brew still had it on record:
  `brew uninstall --cask --force netra && brew install --cask netra` (then the `xattr` line)
- **App runs but no stats** → the menu's empty state says why (since v0.1.2).
  From a terminal:
  `/Applications/Netra.app/Contents/Resources/ccusage-bin daily --json --offline | head -c 300`
  and `log show --last 10m --predicate 'subsystem == "com.sahabji0P.netra"' --info`

## Develop

```sh
./run.sh          # debug build + (re)start in the menu bar
pkill -f Netra    # stop
swift test        # contract tests against captured fixtures
```

## Release (maintainer)

```sh
scripts/build-app.sh 0.1.2    # assemble + sign dist/Netra.app
scripts/release.sh 0.1.2      # zip → GitHub Release → bump Homebrew cask
```

`release.sh` notarizes when `NETRA_NOTARY_PROFILE` is set (paid Apple
Developer membership); otherwise it releases un-notarized and users must clear
quarantine with the `xattr` command above.

Before publishing, `release.sh` checks npm for a newer
`@ccusage/ccusage-darwin-arm64` and stops if `ccusage-bin` is behind. Review
the ccusage changelog, replace the binary, and run `swift test` (which runs the
pinned binary against synthetic logs in `PinnedCCUsageTests`) — or set
`NETRA_ALLOW_OLD_CCUSAGE=1` to ship on the pinned version deliberately.

## Layout

- `Sources/Netra/` — the app (SwiftUI `MenuBarExtra`, window-style popover)
  - `CCUsageClient.swift` — actor that runs the pinned native ccusage binary
  - `UsageStore.swift` — snapshot state machine (empty/refreshing/fresh/stale/failed) + last-success cache
  - `CursorUsageEvents.swift` — Cursor usage-event parsing, paged fetch, and the incremental on-disk store
  - `CursorUsageFetcher.swift` — Cursor cycle tokens, API-rate value, and quota windows
  - `Dashboard*.swift` — full Usage and Settings window
  - `AppPreferences.swift` / `UsageAlerts.swift` — persisted display choices and threshold notifications
  - `AwakeController.swift` — IOKit sleep assertion (manual/timed), lock & sleep
  - `MenuView.swift` / `LimitsViews.swift` / `LimitSummary.swift` — the popover UI and limit/pace text rules
- `ccusage-bin` — pinned ccusage 20.0.24 native arm64 binary (from npm `@ccusage/ccusage-darwin-arm64`)
- `VERSION` — next app-bundle version used by local builds (publishing remains explicit)
- `fixtures/` — captured real JSON output + benchmark notes

## Status

Phase A (engine spike) and Phase B (native shell + manual awake) done.
Next: Phase C — FSEvents-driven refresh + agent-activity awake lease.
