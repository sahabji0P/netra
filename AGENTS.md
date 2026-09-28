# Netra Agent Guide

## Project intent

Netra is a native macOS 14+ menu-bar app that gives a glanceable view of
coding-agent usage, estimated cost, provider limits, and keep-awake controls.
It is a Swift 6 executable package, not an iOS app or a reusable framework.

The user defines the product goal and scope. The agent is responsible for
understanding the Swift implementation, choosing sound technical details, and
explaining Swift or macOS concepts in plain language when they affect a
decision. Do not expect the user to supply framework-level implementation
instructions.

## Repository map

- `Package.swift` defines one executable target, `Netra`, and one XCTest target,
  `NetraTests`. The deployment floor is macOS 14.
- `Sources/Netra/NetraApp.swift` is the composition root and `MenuBarExtra`
  entry point.
- `Sources/Netra/MenuView.swift` owns the popover's main state and layout.
  `UsageChartView.swift` and `LimitsViews.swift` extend that view with focused
  UI sections; `AgentPalette.swift` centralizes provider presentation.
- `Sources/Netra/UsageStore.swift` is the `@MainActor` observable snapshot state
  machine. It coordinates refreshes, last-success fallback, and persistence.
- `Sources/Netra/CCUsageClient.swift` is an actor that serializes execution of
  the pinned `ccusage-bin` sidecar. It is the primary usage-data boundary.
- `Sources/Netra/Models.swift` contains external ccusage DTOs and the normalized,
  persisted domain models consumed by the UI.
- `ClaudeQuotaFetcher.swift`, `ClaudeCachedQuotaReader.swift`,
  `CodexQuotaReader.swift`, `CursorUsageFetcher.swift`,
  `CursorUsageEvents.swift`, and `PricingOverrides.swift` adapt secondary or
  unstable external contracts. Codex limits come live from `codex app-server`
  (`account/rateLimits/read`) with session rollouts as the fallback. Cursor
  limits, cycle totals, and per-event history come from Cursor's undocumented
  dashboard API; events are synced incrementally into Netra's app-support
  folder. `JSONValue.swift` holds the shared lenient JSON/ISO-date readers.
- `LimitSummary.swift` normalizes every provider's limit windows (and the
  pace/reset text rules) for both the popover and the menu-bar icon.
- `AwakeController.swift`, `LaunchAtLogin.swift`, and `UpdateChecker.swift` wrap
  macOS or distribution services.
- `Tests/NetraTests/` contains XCTest contract tests and captured fixtures for
  external formats. `fixtures/` at the root contains exploratory captures and
  benchmark notes rather than test resources.
- `run.sh` builds, signs, and restarts a development build. `scripts/` assembles
  and publishes the distributable app. `packaging/` contains shipped assets.

## Architecture and implementation rules

- Keep SwiftUI-facing mutable state on `@MainActor`. Do not move blocking file,
  process, Keychain, or network work onto the main actor.
- Preserve actor isolation in `CCUsageClient`: process execution is serialized,
  both output pipes are drained concurrently, and the timeout must remain able
  to run while the child process is active.
- Treat the unified ccusage report as the primary refresh. Quota, block, update,
  and pricing enrichment are secondary: their failure must degrade gracefully
  and must not erase a valid usage snapshot.
- A failed refresh must never overwrite the last successful snapshot. Preserve
  freshness provenance (`fetchedAt`, observed timestamps, and stale UI labels)
  across fallbacks.
- Keep transport DTOs separate from normalized UI/persistence models. When an
  external JSON or JSONL shape changes, update the adapter and add or update a
  captured fixture plus a contract test.
- Never log, persist, fixture, or expose real OAuth tokens, Keychain payloads,
  personal session contents, or other secrets. Test credentials must be
  unmistakably synthetic.
- Keep `ccusage-bin` pinned and offline-first. Do not replace or upgrade the
  binary, change its license bundle, or alter pricing provenance without
  explicit approval and contract verification.
- Maintain the compact, glanceable menu-bar UI. Provider colors and display
  names belong in `AgentPalette`; avoid duplicating them in individual views.
- Prefer focused extensions or small types when a view or adapter gains a
  distinct responsibility. Do not perform unrelated repository-wide cleanup.
- Do not add a dependency when Foundation, SwiftUI, Charts, Observation, or a
  small local implementation already covers the need. Ask before adding any
  production dependency.
- User-facing behavior, installation steps, or release behavior changes require
  a matching `README.md` update.

## Working method

1. Inspect the relevant caller, state owner, adapter, and tests before editing.
2. State the behavioral contract being changed and identify failure/fallback
   behavior. Do not infer an external provider schema from a type name alone.
3. Make the smallest coherent change and preserve unrelated working-tree edits.
4. Add regression coverage for parsing, mapping, persistence, or state-machine
   behavior. Prefer fixtures over live provider, Keychain, or session data.
5. Run validation proportional to the change and report exactly what ran and
   what could not be verified.

Do not tag, release, push, modify the Homebrew tap, or commit changes unless the
user explicitly asks for that action. The release scripts mutate external state
and are not ordinary validation commands.

## Build and validation

Run commands from the repository root.

- `swift build` — compile the debug executable.
- `swift test` — run the full XCTest suite; required for source or test changes.
- `swift test --filter ContractTests` — focused external-contract tests.
- `swift test --filter PricingOverridesTests` — focused pricing tests.
- `zsh -n run.sh scripts/build-app.sh scripts/release.sh` — syntax-check shell
  scripts after editing them.
- `git diff --check` — check every change for whitespace errors.
- `./run.sh` — build, sign, and restart the live menu-bar app. Use it only when
  interactive UI verification is appropriate; it terminates any running Netra
  development process.
- `scripts/build-app.sh <version>` — verify app-bundle assembly only when
  packaging changed. It rewrites `dist/Netra.app` and performs code signing.

For a SwiftUI change, `swift build` proves compilation, not visual correctness.
Inspect the running popover when possible and explicitly say if visual QA was
not completed. Never use `scripts/release.sh` as a test.

## Commit message contract

When the user asks for a commit, use Conventional Commits and make the message
record both the completed task and its engineering rationale:

```text
<type>(<optional-scope>): <task or outcome>

<what changed, when the subject alone is not enough>
Why: <reason, constraint, or tradeoff that explains the chosen change>

Tests: <validation actually run, or "not run" with a reason>
```

Rules:

- Use `feat`, `fix`, `refactor`, `test`, `docs`, `build`, `perf`, or `chore`.
- Write the subject as a concrete, imperative outcome, for example
  `feat(usage): capture usage from additional coding agents`.
- Keep the subject to 72 characters when practical, with no trailing period.
- The body is required for every non-trivial commit. Explain the reviewable
  rationale and important tradeoffs, not a step-by-step internal thought
  process. A reader should understand why this implementation exists.
- Include only tests that actually ran. Never fabricate an issue reference,
  motivation, result, co-author, or validation claim.
- Keep one logical task per commit. If a change needs two unrelated subjects or
  two unrelated reasons, split it before committing.
- Use `BREAKING CHANGE: <impact and migration>` as a footer when applicable.

Examples:

```text
feat(usage): capture usage from additional coding agents

Add provider-specific adapters and normalize their totals into UsageSnapshot.
Why: keeping provider parsing outside the view preserves fallback behavior and
makes unstable log formats independently testable.

Tests: swift test
```

```text
fix(pricing): backfill models missing from the offline price table

Fetch and persist a targeted override before rescanning the unified report.
Why: online scans are too slow for the refresh loop, while accepting zero-cost
rows silently corrupts every aggregate shown to the user.

Tests: swift test --filter PricingOverridesTests
```
