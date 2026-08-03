# Netra (नेत्र — "the eye")

macOS menu-bar app: a glanceable view of coding-agent token usage and estimated
cost, plus agent-aware keep-awake. Vision doc: `../netra-product-vision.html`.

## Run

```sh
./run.sh          # build + (re)start in the menu bar
pkill -f Netra    # stop
```

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
