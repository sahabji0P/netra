# Netra on Rust: the main window (GPUI) and its core

Netra is two processes. The Swift app in `Sources/Netra` lives in the menu
bar: it runs ccusage, fetches limits, owns preferences, sign-ins and the
Keychain, and writes Netra's data files. This workspace is the main window:
a [GPUI](https://www.gpui.rs) app that reads those files and shows Usage,
Subscriptions, Accounts and every settings page. macOS only for now.

The window never changes anything itself. To change a setting, switch an
account, refresh, or import a history file, it drops a small command file
that the Swift app picks up, checks and carries out; the result comes back in
the state file the Swift app writes. No secret crosses in either direction.
The whole contract is in [`docs/dashboard-bridge.md`](../docs/dashboard-bridge.md).

See [`docs/portable-engine.md`](../docs/portable-engine.md) for where this is
heading and what is still open.

## Layout

```
rust/
  Cargo.toml                 workspace; gpui pinned to =0.2.2 (crates.io)
  crates/
    netra-core/              no UI, no macOS API — the part a Windows app could share
      src/time.rs            Swift dates (seconds since 2001-01-01), local day keys
      src/model.rs           ModelStat / AgentStat / PeriodRow (persisted JSON shapes)
      src/history.rs         usage-history.json reader
      src/snapshot.rs        snapshot.json reader: limits, active block (no account ids)
      src/bridge.rs          dashboard-state.json reader and the command-file writer
      src/library.rs         polling + "a bad read never erases the last good one"
      src/aggregate.rs       Usage page sums (port of DashboardUsageAggregator)
      src/limits.rs          provider limits, reset and pace text (port of LimitSummary)
      src/palette.rs         provider colors and names as plain data (port of AgentPalette)
      src/format.rs          cost / token / age formatting (port of Format)
      tests/contract.rs      synthetic fixtures + ports of the Swift tests
      examples/summary.rs    prints the live numbers in the terminal
    netra-dashboard/         the GPUI window
      assets/                icons and provider marks (SVG), compiled into the binary
      src/main.rs            app bootstrap, menu, one window
      src/assets.rs          the embedded asset source
      src/store.rs           UsageStore entity: polling, commands sent, toasts
      src/dashboard.rs       root view: sidebar, selected page, toasts
      src/theme.rs           light/dark tokens, provider colors from the palette
      src/components.rs      panel, stat tile, meter, toggle, button, stepper, segmented control
      src/pages/usage.rs     KPIs, activity chart, providers, tokens, breakdown, calendar
      src/pages/subscriptions.rs  limit cards, resets, pace, 5-hour block
      src/pages/accounts.rs  managed Claude Code and Codex accounts
      src/pages/settings.rs  Menu Bar, Limits, Providers, Notifications, General
```

Rules that carry over from the Swift app:

- Usage totals come from `usage-history.json` (the recorded days), never from
  ccusage's weekly or monthly sections.
- A missing or half-written file keeps the last good data on screen with a
  notice; it is read again on the next poll.
- Provider colors and names live only in `palette.rs`.
- Fixtures are synthetic. The live `snapshot.json` carries account ids and is
  never copied into the repo; the reader does not even decode them.
- The only thing this workspace writes is `commands/<id>.json` in Netra's
  data folder. Never the history, the snapshot, preferences, or a sign-in.

## Run

Needs Rust (stable) and Xcode's Metal toolchain (gpui compiles its shaders).
From `rust/`:

```sh
cargo run -p netra-dashboard                        # follows ~/Library/Application Support/Netra
cargo run -p netra-dashboard -- --page subscriptions
NETRA_DATA_DIR=/path/to/folder cargo run -p netra-dashboard
cargo run -p netra-core --example summary           # same numbers, in the terminal
NETRA_APPEARANCE=light cargo run -p netra-dashboard # pin light or dark colors
```

The first build compiles gpui and takes a few minutes. Netra's Swift app must
have run at least once so its files exist; the window says so if they don't.
Settings and Accounts need the Swift app running, since it carries out every
change. `scripts/build-app.sh` builds this in release mode and puts it inside
`Netra.app` as `Contents/Helpers/Netra Dashboard.app`; the popover's
dashboard button opens it.

## Check

```sh
cargo test --workspace
cargo clippy --workspace --all-targets
cargo fmt --all --check
```

## Not here yet

- The menu bar, popover and notch island stay in Swift. GPUI has no tray API.
- No text fields: a nickname, the website endpoint and its token are typed
  into a prompt the Swift app shows.
- Windows: the core has no macOS dependency except the default data folder in
  `paths.rs`; the dashboard has not been built or tried there.
