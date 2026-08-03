# Netra (नेत्र — "the eye")

macOS menu-bar app: a glanceable view of coding-agent token usage and estimated
cost, plus agent-aware keep-awake. Vision doc: `../netra-product-vision.html`.

## Install (Homebrew)

```sh
brew tap sahabji0P/tap
brew install --cask --no-quarantine netra   # --no-quarantine until notarized
```

Update later with `brew upgrade netra`. The app shows a quiet notice in its
footer when a newer release exists.

## Develop

```sh
./run.sh          # debug build + (re)start in the menu bar
pkill -f Netra    # stop
swift test        # contract tests against captured fixtures
```

## Release (maintainer)

```sh
scripts/build-app.sh 0.1.0    # assemble + sign dist/Netra.app
scripts/release.sh 0.1.0      # zip → GitHub Release → bump Homebrew cask
```

`release.sh` notarizes when `NETRA_NOTARY_PROFILE` is set (paid Apple
Developer membership); otherwise it releases un-notarized and the cask's
`--no-quarantine` caveat applies.

## Layout

- `Sources/Netra/` — the app (SwiftUI `MenuBarExtra`, window-style popover)
  - `CCUsageClient.swift` — actor that runs the pinned native ccusage binary
  - `UsageStore.swift` — snapshot state machine (empty/refreshing/fresh/stale/failed) + last-success cache
  - `AwakeController.swift` — IOKit sleep assertion (manual/timed), lock & sleep
  - `MenuView.swift` — the popover UI
- `ccusage-bin` — pinned ccusage 20.0.19 native arm64 binary (from npm `@ccusage/ccusage-darwin-arm64`)
- `fixtures/` — captured real JSON output + benchmark notes

## Status

Phase A (engine spike) and Phase B (native shell + manual awake) done.
Next: Phase C — FSEvents-driven refresh + agent-activity awake lease.
