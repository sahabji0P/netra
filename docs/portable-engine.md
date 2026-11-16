# Portable engine: idea and open questions

Status: an idea recorded on 2026-11-15. On 2026-11-16 the first step was
taken in [`rust/`](../rust/README.md): a `netra-core` crate that reads Netra's
files and ports the Usage-page sums and limit text rules, and a GPUI app over
it that is now Netra's main window (macOS only). The Swift app is still the
engine: it runs ccusage, owns preferences and sign-ins, and carries out every
change the window asks for ([`dashboard-bridge.md`](dashboard-bridge.md)).
Moving the engine itself is still undecided; the rest of this note stands.

## The idea

Move Netra's usage engine out of the Swift app into a Rust core, so the same
code runs on macOS and Windows. The Swift app keeps the menu bar, popover, and
notch island and reads from the core. A Windows app would be a tray shell over
the same core. The dashboard window could become a GPUI app that links the
core directly, giving one dashboard codebase for both systems.

## What the engine is today

| Part | Where it lives now | Tied to macOS? |
|---|---|---|
| Usage history (`usage-history.json`): per-day, per-agent, per-model tokens and cost, and the rule that a reading may raise or reprice a day but never lower it | `UsageLedger.swift` | No. A JSON file and a merge rule. |
| Scan policy: read three days normally; read everything on first run, after a ccusage upgrade, when a price is filled in, and once a day | `UsageLedger.swift`, `UsageStore.swift` | No |
| Running ccusage and decoding its report | `CCUsageClient.swift`, `Models.swift` | No. ccusage publishes `win32-x64` and `win32-arm64` builds. |
| Pricing overrides and the pricing audit | `PricingOverrides.swift`, `PricingAudit.swift` | No. HTTP and JSON. |
| Cursor event history and its daily totals | `CursorUsageEvents.swift` | Reading Cursor's saved login is; the rest is not. |
| Provider limits (Claude, Codex, Cursor) | `ClaudeQuotaFetcher.swift`, `ClaudeCachedQuotaReader.swift`, `CodexQuotaReader.swift`, `CursorUsageFetcher.swift` | Partly. They read each agent's files and the macOS Keychain. |
| Account switching | `Account*.swift`, `ClaudeAccountSession.swift`, `CodexAccountSession.swift` | Yes. Built on the macOS Keychain and `/usr/bin/security`. |
| Menu bar, popover, notch island, dashboard | SwiftUI views | Yes |

The first four rows are the natural core: they have no macOS dependency and
already sit behind one file format. The Swift app could read that file, or
call the core as a sidecar the way it calls ccusage now.

## What a Rust core would not solve

- **The tray and popover on Windows.** GPUI has no system-tray or menu-bar
  API, and its crates.io release has not been updated by Zed since October
  2025 (checked 2026-11-15). Windows needs its own tray UI whatever the core
  is written in. A Windows tray icon also cannot show text, so the percentage
  would be drawn into the icon.
- **Limits and account switching on Windows.** These depend on where Claude
  Code and Codex keep their sign-ins. On macOS that is the Keychain and files
  under the home folder. How each CLI stores credentials on Windows has not
  been checked.
- **Two UI stacks on the Mac.** If the dashboard moves to GPUI while the menu
  bar stays in Swift, the Mac app ships both, and the dashboard and settings
  (about 3,000 lines of SwiftUI plus charts) are rewritten.

## A possible order

1. Define the contract the core exposes: the history file as it is, plus a
   small command-line interface (`refresh`, `history`, `snapshot`) that prints
   JSON. The Swift app switches to it without any visible change.
2. Port the core to Rust behind that contract and keep the Swift tests that
   pin its behaviour (`UsageLedgerTests`, `PinnedCCUsageTests`) passing
   against it.
3. Only then choose the Windows shell and whether the dashboard moves to
   GPUI. Both can be tried as spikes against a core that already works.

Step 1 is useful on its own and commits to nothing.

## Open questions

- Sidecar process or linked library for the Swift app? A sidecar matches how
  ccusage is used today and keeps the Swift build simple; a library avoids a
  process launch per refresh.
- Does the core own limits too, or only usage? Limits are where the
  platform-specific code is.
- Is a Windows version worth a second tray UI, given that the popover and
  limits are most of what people use?
- Multi-device totals were deferred. A shared core and a per-device history
  file would make them simpler; this plan should not block that.
