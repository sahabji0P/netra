# Notch island: plan and contracts

Netra gains a notch "island": a black panel over the MacBook camera notch that
blends with it, shows a tiny resting summary, grows briefly for live
activities, and expands on hover/click into one place for limits, accounts,
banked resets, and usage stats. The menu-bar icon stays available (clamshell
mode and external displays have no notch); non-notch screens get the same
island as a centered pill at the top.

Integration branch: `feat/notch-island` (from `master`). Each workstream
commits on its own `feat/island-*` branch from it; the coordinator merges.
Nothing is pushed.

## Approved design

- Resting: provider logo + small ring of the tightest limit on the left of the
  notch, today's cost on the right.
- Live activities: running hot (crossed the alert threshold), limit reached
  (big live countdown to reset), window reset ("Codex is fresh again"),
  account switched, keep awake.
- Expanded: header with today's spend; one card per provider (Claude Code,
  Codex, Cursor) with the provider's official logo, a soft provider-color glow,
  the active account, concentric rings (outer = shortest window, inner =
  longer window), a white tick at the elapsed fraction of each window, a big
  reset countdown, and a pace badge. Below: account list/switcher, banked
  resets, stats strip, keep-awake toggle.
- Reference mockup values: black island, cards #111114, track #26262b,
  radius 20 cards / 32 expanded bottom corners. Tokens live in `IslandTheme`.

## Shared contracts (already on the integration branch)

- `IslandTheme` (IslandTheme.swift): colors, radii, the one morph spring.
- `ProviderLogo(agent:size:)` (ProviderLogo.swift): stub dot; replaced by the
  logos workstream. Every view uses it for provider marks.
- `IslandActivity` (IslandActivity.swift): the event value type.
- `IslandStatsStrip(snapshot:preferences:)` (IslandStatsView.swift): stub;
  replaced by the stats workstream.

Do not change these signatures without telling the coordinator. Adding
members is fine.

## Workstreams

| ID | Branch | Owns (new files unless noted) |
|----|--------|-------------------------------|
| A shell | feat/island-shell | NotchGeometry.swift, IslandPanel.swift, IslandController.swift |
| B cards | feat/island-cards | IslandViews.swift, IslandLimitCards.swift, IslandAccountsView.swift, Tests/IslandRenderPreview.swift |
| C stats | feat/island-stats | IslandStatsView.swift (replace stub), stats tests |
| D logos | feat/island-logos | ProviderLogo.swift (replace stub), logo tests, Package.swift/build-app.sh only if resources are used |
| E activity | feat/island-activity | IslandActivityDetector.swift, IslandActivityQueue.swift, tests |
| F integration | feat/notch-island | NetraApp.swift, AppPreferences.swift, Settings toggle, README.md |

### A shell contract
`@MainActor final class IslandController` hosting three SwiftUI roots supplied
as closures: compact, expanded, activity(IslandActivity). Modes: resting,
peek (hover), expanded (click or hover hold), activity. Collapses when the
pointer leaves. Non-activating borderless NSPanel above the menu bar,
`.canJoinAllSpaces, .stationary, .fullScreenAuxiliary`, notch geometry from
`NSScreen.auxiliaryTopLeftArea/TopRightArea`, pill fallback otherwise,
follows screen changes. Must not steal focus or block clicks outside its
visible shape.

### B cards contract
`IslandCompactView(store:preferences:awake:)`,
`IslandExpandedView(store:preferences:accounts:awake:)`,
`IslandActivityView(activity:)`. Limits from `snapshot.providerLimits(order:)`,
tick from `QuotaWindow.elapsedFraction`, pace from `LimitText.pace/paceText`,
reset text from `LimitText.reset/duration`, banked resets from
`ProviderLimits.resetCredits` / `LimitText.bankedResets` (display only).
Accounts from `AccountStore.accounts(for:)`, `activeAccount`, `parkedAccounts`,
`lastKnownLimits`, switching only via `AccountStore.switchTo`. List every
saved account, not just two.

### C stats contract
Replace the 7-day stacked bars in the island with: today's cost and tokens
with change vs the 7-day average, a 30-day activity heatmap strip, model mix
(top models as one stacked bar), token mix with cache hit rate, and the
active 5-hour block's burn rate and projected cost (`activeBlock`). Reuse
`DashboardUsageAggregator` helpers where they fit.

### E activity contract
Reuse existing detection: reset celebrations (`ResetCelebrationDetector` /
`UsageStore.celebrationHandler`) and the alert threshold
(`AppPreferences.providerLimitAlertThreshold`); do not add a second rollover
detector. Pure detector (old snapshot, new snapshot, threshold → activities)
plus a `@MainActor` queue that dedupes, prioritises (limit reached > hot >
reset > account > awake), and shows each for a few seconds.

## Rules for every workstream

- Use `/usr/bin/swift` (PATH swift is the wrong toolchain).
- `/usr/bin/swift build` and `/usr/bin/swift test` must pass before you finish.
- No production dependencies. Follow AGENTS.md, especially the account rules.
- Commit only on your own branch, Conventional Commits per AGENTS.md. No push.
- Report what you ran, what you could not verify, and any contract change.
