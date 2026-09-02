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

The dashboard shows provider activity, equivalent API cost, token composition,
model/day breakdowns, and available limits — always for **every** provider
found in your local logs. The menu-bar popover is the curated view: Settings →
Providers lets you toggle which providers appear there (hidden providers are
removed from the popover's totals too, so its numbers stay consistent).

**Cursor** keeps no usage data on local disk, so it's opt-in: turn on **Cursor
usage** in Settings and Netra reads the login Cursor already saved on this Mac
and queries Cursor's own account API for your included-usage and on-demand
spend (with the billing-cycle reset). The login is sent only to cursor.com;
this uses an undocumented endpoint that can change without notice.

Limits: Codex limits are provider-reported from local rollout data. Claude
limits are Anthropic's real percentages, read from the response Claude Code
itself caches in `~/.claude.json` — including the model-scoped weekly bucket
and your plan tier, with no Keychain access and no network. Turn on **Live
Claude limits** in Settings to fetch fresh numbers directly from Anthropic on
every refresh using the sign-in Claude Code already keeps in the Keychain —
macOS asks once (choose "Always Allow"); the token is only ever sent to
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

## Layout

- `Sources/Netra/` — the app (SwiftUI `MenuBarExtra`, window-style popover)
  - `CCUsageClient.swift` — actor that runs the pinned native ccusage binary
  - `UsageStore.swift` — snapshot state machine (empty/refreshing/fresh/stale/failed) + last-success cache
  - `Dashboard*.swift` — full Usage and Settings window
  - `AppPreferences.swift` / `UsageAlerts.swift` — persisted display choices and threshold notifications
  - `AwakeController.swift` — IOKit sleep assertion (manual/timed), lock & sleep
  - `MenuView.swift` — the popover UI
- `ccusage-bin` — pinned ccusage 20.0.19 native arm64 binary (from npm `@ccusage/ccusage-darwin-arm64`)
- `VERSION` — next app-bundle version used by local builds (publishing remains explicit)
- `fixtures/` — captured real JSON output + benchmark notes

## Status

Phase A (engine spike) and Phase B (native shell + manual awake) done.
Next: Phase C — FSEvents-driven refresh + agent-activity awake lease.
