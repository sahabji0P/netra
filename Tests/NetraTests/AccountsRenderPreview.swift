import AppKit
import SwiftUI
import XCTest
@testable import Netra

/// Dev-only visual QA for the multi-account surfaces, with synthetic accounts
/// over live local usage. Runs only when NETRA_RENDER_DIR is set, e.g.
/// NETRA_RENDER_DIR=/tmp/netra-previews swift test --filter AccountsRenderPreview
@MainActor
final class AccountsRenderPreview: XCTestCase {
    func testRenderAccountPreviews() async throws {
        guard let outputDir = ProcessInfo.processInfo.environment["NETRA_RENDER_DIR"] else {
            throw XCTSkip("set NETRA_RENDER_DIR to render UI previews")
        }
        try FileManager.default.createDirectory(atPath: outputDir, withIntermediateDirectories: true)

        let suiteName = "NetraTests.AccountsRender.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let preferences = AppPreferences(defaults: defaults)
        let store = UsageStore(
            preferences: preferences,
            alerts: UsageAlertController(scheduler: AccountsInertScheduler(), persistence: AccountsInertPersistence()),
            feedFile: UsageFeedFile(url: URL(fileURLWithPath: outputDir).appendingPathComponent("accounts-feed.json")),
            publisher: UsagePublisher(defaults: UserDefaults(suiteName: suiteName)!, version: "render", tokenProvider: { _ in nil }),
            startsAutomatically: false
        )
        await store.refresh()

        let accounts = Self.previewAccounts(withNotice: true)
        let menu = MenuView(
            store: store, awake: AwakeController(), updates: UpdateChecker(),
            preferences: preferences, dashboardNavigation: DashboardNavigation(),
            accounts: accounts, rendersFullHeight: true
        )
        render(menu, name: "accounts-menu", outputDir: outputDir)

        render(
            DashboardAccountsView(accounts: Self.previewAccounts(withNotice: false), store: store, preferences: preferences)
                .frame(width: 860, height: 1180),
            name: "accounts-settings", outputDir: outputDir
        )
        let empty = AccountStore(preview: AccountRoster(), live: Self.live)
        render(
            DashboardAccountsView(accounts: empty, store: store, preferences: preferences)
                .frame(width: 860, height: 900),
            name: "accounts-settings-empty", outputDir: outputDir
        )
        render(
            DashboardSubscriptionsView(
                store: store, preferences: preferences,
                navigation: DashboardNavigation(selection: .subscriptions), accounts: accounts
            )
            .frame(width: 1100, height: 1000),
            name: "accounts-subscriptions", outputDir: outputDir
        )
        render(
            DashboardSubscriptionsView(
                store: store, preferences: preferences,
                navigation: DashboardNavigation(selection: .subscriptions), accounts: accounts, focus: "claude"
            )
            .frame(width: 1100, height: 1000),
            name: "accounts-subscriptions-claude", outputDir: outputDir
        )
    }

    // MARK: Synthetic data

    static let claudeWork = AccountIdentity(
        provider: .claude, providerAccountID: "synthetic-claude-work|org-1",
        email: "ada@work.example", displayName: "Ada Lovelace", organizationName: "Analytical Engines", plan: "Max 20x"
    )
    static let claudePersonal = AccountIdentity(
        provider: .claude, providerAccountID: "synthetic-claude-personal|org-2",
        email: "ada.personal@example.com", displayName: "Ada", organizationName: "ada's Organization", plan: "Pro"
    )
    static let claudeSide = AccountIdentity(
        provider: .claude, providerAccountID: "synthetic-claude-side|org-3",
        email: "lab@side.example", displayName: "Side Lab", plan: "Max 5x"
    )
    static let codexMain = AccountIdentity(
        provider: .codex, providerAccountID: "user-synthetic::acct-main",
        email: "ada@work.example", displayName: "Ada Lovelace", plan: "Pro"
    )
    static let codexTeam = AccountIdentity(
        provider: .codex, providerAccountID: "user-synthetic::acct-team",
        email: "ada@team.example", displayName: "Ada Lovelace", organizationName: "Team Workspace", plan: "Team"
    )

    static var live: [AccountProvider: AccountIdentity] { [.claude: claudeWork, .codex: codexMain] }

    static func previewAccounts(withNotice: Bool) -> AccountStore {
        let now = Date.now
        func limits(_ short: Double, _ weekly: Double, ago: TimeInterval, shortReset: TimeInterval = 3600) -> AccountLimitsRecord {
            AccountLimitsRecord(
                windows: [
                    QuotaWindow(label: "5h", usedPercent: short, resetsAt: now.addingTimeInterval(shortReset), durationSeconds: 5 * 3600),
                    QuotaWindow(label: "weekly", usedPercent: weekly, resetsAt: now.addingTimeInterval(3 * 86400), durationSeconds: 7 * 86400),
                ],
                observedAt: now.addingTimeInterval(-ago), isLive: true
            )
        }
        var roster = AccountRoster()
        roster.accounts = [
            ManagedAccount(id: UUID(), identity: claudeWork, addedAt: now.addingTimeInterval(-86400 * 9),
                           lastActiveAt: now, lastLimits: limits(46, 71, ago: 60)),
            ManagedAccount(id: UUID(), identity: claudePersonal, nickname: "Personal", addedAt: now.addingTimeInterval(-86400 * 5),
                           lastActiveAt: now.addingTimeInterval(-3 * 3600), lastLimits: limits(88, 34, ago: 3 * 3600, shortReset: -600)),
            ManagedAccount(id: UUID(), identity: claudeSide, addedAt: now.addingTimeInterval(-86400 * 2),
                           lastActiveAt: now.addingTimeInterval(-26 * 3600), lastLimits: limits(12, 93, ago: 26 * 3600),
                           signInExpiresAt: now.addingTimeInterval(2 * 86400)),
            ManagedAccount(id: UUID(), identity: codexMain, addedAt: now.addingTimeInterval(-86400 * 4),
                           lastActiveAt: now, lastLimits: limits(20, 40, ago: 90)),
            ManagedAccount(id: UUID(), identity: codexTeam, addedAt: now.addingTimeInterval(-86400 * 3),
                           lastActiveAt: now.addingTimeInterval(-7200), lastLimits: limits(3, 18, ago: 12 * 60)),
        ]
        let notice = withNotice ? AccountNotice(
            provider: .claude, title: "Switched Claude to ada",
            detail: "New sessions use it now; 2 running Claude Code processes keep the previous account until they restart."
        ) : nil
        return AccountStore(preview: roster, live: live, notice: notice)
    }

    // MARK: Rendering

    private func render(_ view: some View, name: String, outputDir: String) {
        for (appearance, suffix) in [(NSAppearance.Name.darkAqua, "dark"), (.aqua, "light")] {
            let hosting = NSHostingView(rootView: view.background(Color(nsColor: .windowBackgroundColor)))
            hosting.appearance = NSAppearance(named: appearance)
            hosting.frame = CGRect(origin: .zero, size: hosting.fittingSize)
            let window = NSWindow(contentRect: hosting.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            window.appearance = hosting.appearance
            window.contentView = hosting
            window.layoutIfNeeded()
            guard let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else { continue }
            hosting.cacheDisplay(in: hosting.bounds, to: rep)
            guard let data = rep.representation(using: .png, properties: [:]) else { continue }
            try? data.write(to: URL(fileURLWithPath: outputDir).appendingPathComponent("\(name)-\(suffix).png"))
        }
    }
}

private struct AccountsInertScheduler: UsageNotificationScheduling {
    func authorizationState() async -> NotificationAuthorizationState { .denied }
    func requestAuthorization() async throws -> Bool { false }
    func schedule(_ candidate: UsageAlertCandidate) async throws {}
}

private actor AccountsInertPersistence: UsageAlertStatePersisting {
    func deliveredKeys() -> Set<String> { [] }
    func setDeliveredKeys(_ keys: Set<String>) {}
}
