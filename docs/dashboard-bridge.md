# Dashboard bridge: how the GPUI window talks to the menu-bar app

The GPUI dashboard (`rust/`) is Netra's main window. The Swift menu-bar app
stays the only process that runs ccusage, owns the usage history, the
preferences, the sign-ins and the Keychain. The two share Netra's data folder
(`~/Library/Application Support/Netra`) and nothing else. `NETRA_DATA_DIR`
redirects the dashboard alone, for fixtures and demos; the Swift app always
uses the Application Support folder, so a redirected dashboard is not bridged:

- **Swift → GPUI**: files the dashboard reads. `usage-history.json` and
  `snapshot.json` as before, plus `dashboard-state.json` (below).
- **GPUI → Swift**: one JSON file per command, dropped into `commands/`.

Rules that do not bend:

- Rust never writes `usage-history.json`, `snapshot.json`, `accounts.json`,
  the preferences plist, the Keychain, or any CLI's sign-in files.
- No secret crosses the bridge in either direction. A command names an
  account by its roster id; a token or nickname is typed into a prompt the
  Swift app shows itself.
- A command is a request, not an order: Swift validates it, may refuse it,
  and reports what happened in `results`.

## `dashboard-state.json` (Swift writes, atomically)

Written when anything in it changes, and once at launch. Dates are ISO 8601
strings with fractional seconds, UTC. Unknown keys are ignored by the reader;
missing optional keys mean "not available".

```jsonc
{
  "version": 1,
  "writtenAt": "2026-11-16T05:40:00.000Z",
  "app": {
    "version": "1.5.0",
    "pid": 4242,                      // so the dashboard can tell Netra is running
    "refreshing": false,
    "lastError": null,                // last refresh error text, or null
    "launchAtLogin": false,
    "launchAtLoginAvailable": true,
    "notifications": "allowed",       // "allowed" | "denied" | "notDetermined" | "checking"
    "claudeKeychainNeedsApproval": false,
    "updateAvailable": null,          // version string or null
    "website": { "tokenSaved": false, "publishing": false, "status": "Never published", "tokenError": null }
  },
  "preferences": {
    // Menu-bar label (see "Menu-bar label" below)
    "menuBarIcon": "eye",             // "eye" | "bars" | "ring" | "none"
    "menuBarItems": ["todayCost"],    // ordered; any of the item ids below
    "menuBarStyle": "plain",          // "plain" | "pill" | "outline"
    "menuBarTint": "mono",            // "mono" | "provider" | "status"
    "menuBarLimitSource": "closest",  // "closest" or an agent name ("claude", "codex", "cursor", "cursor-grok-bot")
    "menuBarCompact": false,          // smaller text, tighter padding
    // Popover
    "showsLimits": true,
    "showsProviderBreakdown": true,
    "showsActivityChart": true,
    "showsKeepAwake": true,
    "hiddenMenuProviders": [],        // lowercased agent names
    "defaultPeriod": "today",         // a `periods` id: "today" | "week" | "month"
    // Limits
    "barsShowRemaining": false,
    "resetTimeStyle": "countdown",    // "countdown" | "clock"
    "showsPace": true,
    "limitProviderOrder": ["claude", "codex", "cursor", "cursor-grok-bot"],  // always the full effective order
    "claudeQuotaEnabled": false,
    "cursorUsageEnabled": false,
    // General
    "confettiOnReset": true,
    "notchIslandEnabled": true,
    // Alerts
    "dailyTokenAlertEnabled": false,
    "dailyTokenAlertThreshold": 1000000,
    "providerLimitAlertEnabled": false,
    "providerLimitAlertThreshold": 80,
    // Website
    "websitePublishEnabled": false,
    "websiteEndpoint": ""
  },
  "periods": [{ "id": "today", "title": "Today" }, { "id": "week", "title": "This week" }, { "id": "month", "title": "This month" }],
  "accounts": {
    "providers": [
      {
        "provider": "claude",          // "claude" | "codex"
        "managing": true,              // the roster holds at least one account of this provider
        "live": { "email": "a@example.com", "displayName": "A", "organization": "Org", "plan": "Team" },  // signed-in identity, or null
        "liveIsSaved": true,           // the live identity is already in the roster
        "switching": false,
        "pendingSignIn": false,
        "note": null,                  // e.g. the Codex keyring warning text
        "accounts": [
          {
            "id": "UUID",
            "title": "Work",           // the nickname when set, else the email
            "email": "a@example.com",
            "plan": "Team",
            "organization": "Org",
            "initials": "W",
            "active": true,
            "attention": null,         // "signInAgain" | "deactivated" | null
            "lastActiveAt": "…",
            "limits": {                // last known limits, or null
              "observedAt": "…", "isLive": true,
              "windows": [{ "label": "5h", "usedPercent": 12.0, "resetsAt": "…", "durationSeconds": 18000 }]
            }
          }
        ]
      }
    ],
    "notice": { "id": "UUID", "provider": "claude", "title": "Switched to Work", "detail": "…", "isError": false }
  },
  "navigate": { "page": "subscriptions", "nonce": 3 },   // set when Swift wants the open window on a page
  "results": [                                            // newest last, at most 20
    { "id": "command uuid", "command": "history.import", "ok": true, "message": "Added 12 days, updated 3.", "at": "…" }
  ]
}
```

No account id from a provider (`providerAccountID`), token, or Keychain payload
is ever written here. The roster `id` is Netra's own UUID.

## `commands/<uuid>.json` (GPUI writes, Swift consumes)

The dashboard writes `commands/<uuid>.json.tmp` and renames it to
`commands/<uuid>.json`. Swift watches the folder, reads each file oldest
first, deletes it, runs it on the main actor, and appends a result. Files
older than 60 seconds at read time are deleted without running (a command
written while Netra was not running must not fire later). A file that does
not parse is deleted and reported as a failed result (under the file name's
id when the file carries none); an expired file is reported as failed too.
`preference.set` also accepts the PeriodTab raw values (`Day`, `Week`,
`Month`) for `defaultPeriod`.

```json
{ "id": "uuid", "command": "preference.set", "at": "2026-11-16T05:40:00.000Z", "args": { "key": "showsPace", "value": false } }
```

| command | args | effect |
| --- | --- | --- |
| `preference.set` | `key`, `value` | Sets one key of `preferences` above. Type and range are validated; side effects are applied by the Swift app (enabling `claudeQuotaEnabled` authorizes the Keychain read, `cursorUsageEnabled` refreshes, website keys reconfigure the publisher). |
| `limits.move` | `provider`, `offset` (-1 or 1) | Moves a provider in the limit order. |
| `provider.setVisible` | `provider`, `visible` | Shows or hides a provider in the popover. |
| `refresh` | | Refreshes usage and limits now. |
| `claude.authorizeKeychain` | | The "Allow Keychain access" button. |
| `launchAtLogin.set` | `enabled` | |
| `notifications.request` | | Asks macOS for notification permission. |
| `notifications.openSettings` | | Opens System Settings on Netra's notifications. |
| `account.startManaging` | `provider` | Saves the live sign-in into the vault. |
| `account.switch` | `id` | Switches to a saved account. |
| `account.beginSignIn` | `provider` | Starts adding an account. |
| `account.cancelSignIn` | | |
| `account.remove` | `id` | Removes an account from Netra (the dashboard confirms first). |
| `account.rename` | `id` | Swift shows a prompt for the nickname. |
| `account.dismissNotice` | | |
| `history.export` | `path` | Writes a copy of the usage history to `path`. |
| `history.import` | `path` | Merges a history file through the ledger. |
| `website.promptToken` | | Swift shows a secure prompt and stores the token in the Keychain. |
| `website.promptEndpoint` | | Swift shows a prompt for the endpoint URL. |
| `website.clearToken` | | |
| `website.publishNow` | | |
| `popover.open` | | Not supported yet; reserved. |

Unknown commands produce a failed result, never a crash.

## Menu-bar label

The label is an optional icon followed by an ordered list of items, drawn in
a style. Item ids:

| id | shows |
| --- | --- |
| `todayCost` | today's API-equivalent cost |
| `todayTokens` | today's tokens |
| `weekCost` | this week's cost |
| `monthCost` | this month's cost |
| `limitPercent` | percent used (or left, following `barsShowRemaining`) of the limit source's tightest window |
| `resetCountdown` | time until that window resets, e.g. `2h 10m` |
| `sessionPercent` | the limit source's short (5-hour) window |
| `weeklyPercent` | the limit source's weekly window |

Icons: `eye` (Netra's mark), `bars` (two limit bars), `ring` (a gauge ring
for the tightest window), `none`. Styles: `plain` (text on the menu bar),
`pill` (filled capsule, text knocked out), `outline` (stroked capsule).
Tint: `mono` (template image, follows the menu bar), `provider` (the limit
source's color), `status` (green, amber from 75%, red from 90%).

The old single `menuBarDisplayMode` setting maps onto this the first time the
new keys are read, so an existing choice is kept:

| old | icon | items |
| --- | --- | --- |
| `iconOnly` | `eye` | none |
| `limitBars` | `bars` | none |
| `todayCost` | `eye` | `todayCost` |
| `todayTokens` | `eye` | `todayTokens` |
| `highestProviderLimit` | `eye` | `limitPercent` |

## Launching

"Open dashboard" in the popover or the island starts the GPUI app when it is
found (the nested `Netra.app/Contents/Helpers/Netra Dashboard.app`, or the
binary named by `NETRA_DASHBOARD_BIN`), passing `--page <id>`. When it is
already running, Swift activates it and sets `navigate`. When it is not found
(a plain `swift build` with no `NETRA_DASHBOARD_BIN`), Netra says the window
is missing from the build; there is no other dashboard.

Page ids: `usage`, `subscriptions`, `accounts`, `menubar`, `limits`,
`providers`, `notifications`, `general`.

## Importing a history file

`history.import` goes through `UsageLedger`, under a stricter rule than a
reading of the logs: an imported entry is taken only when the day has none
for that agent, or the file's carries strictly more tokens. Equal tokens
change nothing, so a file with older prices can never reprice a recorded
day. The file's `completeScanAt` and `engine` are ignored, so this Mac still
does its own complete scan. Importing the same file twice changes nothing.
A file that does not parse is refused and nothing is written.
Two Macs' usage of the same agent on the same day is not added together
(multi-device totals are deferred): the larger entry wins.
