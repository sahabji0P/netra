import AppKit
import Observation
import UserNotifications
import os

/// macOS services the bridge's commands reach, behind a protocol so nothing
/// in tests touches notifications, login items, or modal prompts.
@MainActor
protocol DashboardSystemServices {
    var launchAtLoginAvailable: Bool { get }
    var launchAtLoginEnabled: Bool { get }
    func setLaunchAtLogin(_ enabled: Bool)
    /// False outside a real app bundle, where UNUserNotificationCenter throws.
    var notificationsAvailable: Bool { get }
    func requestNotificationPermission() async
    func openNotificationSettings()
    /// Asks the user for one line of text in a native alert; nil if cancelled.
    func prompt(title: String, message: String, initial: String, secure: Bool, confirm: String) -> String?
}

@MainActor
struct SystemDashboardServices: DashboardSystemServices {
    var launchAtLoginAvailable: Bool { LaunchAtLogin.isAvailable }
    var launchAtLoginEnabled: Bool { LaunchAtLogin.isEnabled }
    var notificationsAvailable: Bool { Bundle.main.bundlePath.hasSuffix(".app") }

    func setLaunchAtLogin(_ enabled: Bool) {
        LaunchAtLogin.set(enabled)
    }

    func requestNotificationPermission() async {
        _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
    }

    func openNotificationSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension") else { return }
        NSWorkspace.shared.open(url)
    }

    func prompt(title: String, message: String, initial: String, secure: Bool, confirm: String) -> String? {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: confirm)
        alert.addButton(withTitle: "Cancel")
        let field = secure ? NSSecureTextField() : NSTextField()
        field.frame = NSRect(x: 0, y: 0, width: 300, height: 24)
        field.stringValue = initial
        field.usesSingleLineMode = true
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        // Asked for from the dashboard window: stay in front of it.
        alert.window.level = .floating
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        return field.stringValue
    }
}

/// The Swift end of the dashboard bridge (docs/dashboard-bridge.md): mirrors
/// the app's state into `dashboard-state.json` and runs the commands the GPUI
/// dashboard drops into `commands/`. Swift stays the only writer of data,
/// preferences, and sign-ins; a command is a request this type validates.
@MainActor
final class DashboardBridge {
    static var defaultDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Netra", isDirectory: true)
    }

    let directory: URL
    var stateURL: URL { directory.appendingPathComponent("dashboard-state.json") }
    var commandsURL: URL { directory.appendingPathComponent("commands", isDirectory: true) }

    private let preferences: AppPreferences
    private let store: UsageStore
    private let accounts: AccountStore
    private let updates: UpdateChecker
    private let services: DashboardSystemServices
    private let writer = DashboardStateWriter()
    private let log = Logger(subsystem: "com.sahabji0P.netra", category: "bridge")

    private var results: [DashboardState.CommandResult] = []
    private var navigate: DashboardState.Navigate?
    /// Seeded from the clock so a dashboard that outlived a Netra restart
    /// still sees a new nonce.
    private var nonce = Int(Date.now.timeIntervalSince1970 * 1000)
    private var lastWritten: Data?
    private var writeSequence = 0
    private var writeScheduled = false
    private var watcher: DispatchSourceFileSystemObject?
    private var scanning = false
    private var rescanRequested = false
    private var heartbeat: Task<Void, Never>?

    init(
        directory: URL = DashboardBridge.defaultDirectory,
        preferences: AppPreferences,
        store: UsageStore,
        accounts: AccountStore,
        updates: UpdateChecker,
        services: DashboardSystemServices = SystemDashboardServices()
    ) {
        self.directory = directory
        self.preferences = preferences
        self.store = store
        self.accounts = accounts
        self.updates = updates
        self.services = services
    }

    /// Writes the state once, then follows every change; watches and scans
    /// the command inbox. Call once the app has finished launching.
    func start() {
        try? FileManager.default.createDirectory(at: commandsURL, withIntermediateDirectories: true)
        writeNow()
        startWatching()
        scanInbox()
        // Login-item and notification permission are not observable; read
        // them now and then. An unchanged state is not rewritten.
        heartbeat = Task { [weak self] in
            while !Task.isCancelled {
                if self?.services.notificationsAvailable == true {
                    await self?.preferences.refreshNotificationAuthorization()
                }
                self?.scheduleWrite()
                try? await Task.sleep(for: .seconds(30))
            }
        }
    }

    /// Stops watching the inbox and the heartbeat.
    func stop() {
        heartbeat?.cancel()
        heartbeat = nil
        watcher?.cancel()
        watcher = nil
    }

    /// Asks the open dashboard window to show `page`.
    func navigate(to page: String) {
        nonce += 1
        navigate = DashboardState.Navigate(page: page, nonce: nonce)
        writeNow()
    }

    // MARK: State

    private func buildState() -> DashboardState {
        let lastError: String? = if case .failed(let message) = store.state { message } else { nil }
        let app = DashboardState.App(
            version: UsageStore.appVersion,
            pid: ProcessInfo.processInfo.processIdentifier,
            refreshing: store.state == .refreshing,
            lastError: lastError,
            launchAtLogin: services.launchAtLoginEnabled,
            launchAtLoginAvailable: services.launchAtLoginAvailable,
            notifications: DashboardState.notificationsValue(preferences.notificationAuthorizationState),
            claudeKeychainNeedsApproval: store.claudeKeychainNeedsApproval,
            updateAvailable: updates.availableVersion,
            website: DashboardState.Website(
                tokenSaved: store.websiteTokenSaved,
                publishing: store.isPublishing,
                status: DashboardState.websiteStatus(
                    enabled: preferences.websitePublishEnabled, state: store.publishState
                ),
                tokenError: store.websiteTokenError
            )
        )
        let accountsSection = DashboardState.accounts(
            roster: accounts.roster,
            live: accounts.liveIdentities,
            switching: accounts.switching,
            pendingSignIn: accounts.pendingSignIn?.provider,
            codexUsesKeyring: accounts.codexUsesKeyring,
            notice: accounts.notice
        )
        return DashboardState(
            writtenAt: .now,
            app: app,
            preferences: DashboardState.Preferences(preferences),
            periods: DashboardState.periodList,
            accounts: accountsSection,
            navigate: navigate,
            results: results
        )
    }

    /// Coalesces bursts of changes into one write.
    private func scheduleWrite() {
        guard !writeScheduled else { return }
        writeScheduled = true
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(150))
            guard let self else { return }
            writeScheduled = false
            writeNow()
        }
    }

    /// Builds the state under observation (re-armed on every build, since
    /// tracking fires once), and writes it unless only `writtenAt` changed.
    private func writeNow() {
        var state = withObservationTracking {
            buildState()
        } onChange: { [weak self] in
            Task { @MainActor in self?.scheduleWrite() }
        }
        let encoder = DashboardJSON.encoder()
        let writtenAt = state.writtenAt
        state.writtenAt = .distantPast
        guard let comparable = try? encoder.encode(state), comparable != lastWritten else { return }
        state.writtenAt = writtenAt
        guard let data = try? encoder.encode(state) else { return }
        lastWritten = comparable
        writeSequence += 1
        let url = stateURL, sequence = writeSequence
        Task { await writer.write(data, to: url, sequence: sequence) }
    }

    // MARK: Inbox

    private func startWatching() {
        let descriptor = open(commandsURL.path, O_EVTONLY)
        guard descriptor >= 0 else {
            log.error("commands folder cannot be watched")
            return
        }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor, eventMask: [.write, .extend, .rename], queue: .main
        )
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.scanInbox() }
        }
        source.setCancelHandler { close(descriptor) }
        source.resume()
        watcher = source
    }

    private func scanInbox() {
        guard !scanning else {
            rescanRequested = true
            return
        }
        scanning = true
        let commands = commandsURL, data = directory
        Task { [weak self] in
            let drained = await Task.detached { DashboardInbox.drain(directory: commands, dataDirectory: data) }.value
            guard let self else { return }
            for id in drained.expired {
                record(id: id, command: "unknown", ok: false, message: "Expired: written more than a minute ago.")
            }
            for request in drained.requests {
                switch request.command {
                case .failure(let failure):
                    record(id: request.id, command: request.name, ok: false, message: failure.message)
                case .success(let command):
                    // Each runs in order on the main actor; slow ones (a
                    // switch, a refresh) do not hold up the rest.
                    Task { [weak self] in
                        guard let self else { return }
                        let (ok, message) = await execute(command)
                        record(id: request.id, command: request.name, ok: ok, message: message)
                    }
                }
            }
            scanning = false
            if rescanRequested {
                rescanRequested = false
                scanInbox()
            }
        }
    }

    private func record(id: String, command: String, ok: Bool, message: String) {
        results = DashboardState.appending(
            DashboardState.CommandResult(id: id, command: command, ok: ok, message: message, at: .now),
            to: results
        )
        writeNow()
    }

    // MARK: Commands

    private func execute(_ command: DashboardCommand) async -> (Bool, String) {
        switch command {
        case .preferenceSet(let change):
            return apply(change)
        case .limitsMove(let provider, let offset):
            preferences.moveLimitProvider(provider, by: offset)
            return (true, "Moved \(AgentPalette.shortName(provider)).")
        case .providerSetVisible(let provider, let visible):
            preferences.setProvider(provider, visibleInMenu: visible)
            return (true, "\(AgentPalette.displayName(provider)) is \(visible ? "shown" : "hidden") in the popover.")
        case .refresh:
            await store.refresh()
            if case .failed(let message) = store.state { return (false, message) }
            return (true, "Refreshed.")
        case .claudeAuthorizeKeychain:
            await store.authorizeClaudeKeychain()
            return store.claudeKeychainNeedsApproval
                ? (false, "Keychain access wasn't allowed.")
                : (true, "Keychain access checked.")
        case .launchAtLoginSet(let enabled):
            guard services.launchAtLoginAvailable else {
                return (false, "Launch at login needs Netra's signed app bundle.")
            }
            services.setLaunchAtLogin(enabled)
            scheduleWrite()
            let now = services.launchAtLoginEnabled
            return (now == enabled, now ? "Netra launches at login." : "Netra doesn't launch at login.")
        case .notificationsRequest:
            guard services.notificationsAvailable else { return (false, "Notifications need Netra's app bundle.") }
            await services.requestNotificationPermission()
            await preferences.refreshNotificationAuthorization()
            return (true, "Notifications: \(DashboardState.notificationsValue(preferences.notificationAuthorizationState)).")
        case .notificationsOpenSettings:
            services.openNotificationSettings()
            return (true, "Opened Notification Settings.")
        case .accountStartManaging(let provider):
            await accounts.startManaging(provider)
            return accounts.isManaging(provider)
                ? (true, "Saved the current \(AgentPalette.shortName(provider.agent)) account.")
                : (false, accounts.notice?.title ?? "No account was saved.")
        case .accountSwitch(let id):
            guard let account = accounts.roster.account(id: id) else { return (false, "That account isn't in Netra.") }
            await accounts.switchTo(account)
            let active = accounts.activeAccount(for: account.provider)?.id == id
            return (active, active ? "Switched to \(accounts.roster.label(for: account))."
                                   : accounts.notice?.detail ?? "Couldn't switch accounts.")
        case .accountBeginSignIn(let provider):
            await accounts.beginSignIn(provider)
            return accounts.pendingSignIn?.provider == provider
                ? (true, "Finish signing in in Terminal.")
                : (false, accounts.notice?.detail ?? "Couldn't start the sign-in.")
        case .accountCancelSignIn:
            accounts.cancelSignIn()
            return (true, "Sign-in cancelled.")
        case .accountRemove(let id):
            guard let account = accounts.roster.account(id: id) else { return (false, "That account isn't in Netra.") }
            await accounts.remove(account)
            return (true, "Removed \(account.title) from Netra.")
        case .accountRename(let id):
            guard let account = accounts.roster.account(id: id) else { return (false, "That account isn't in Netra.") }
            guard let nickname = services.prompt(
                title: "Rename \(account.title)",
                message: "A nickname for this \(AgentPalette.displayName(account.provider.agent)) account. Leave it empty to use the email.",
                initial: account.nickname ?? "", secure: false, confirm: "Rename"
            ) else { return (false, "Cancelled.") }
            await accounts.rename(account, to: nickname.trimmingCharacters(in: .whitespacesAndNewlines))
            return (true, "Renamed.")
        case .accountDismissNotice:
            accounts.dismissNotice()
            return (true, "Dismissed.")
        case .historyExport(let url):
            do {
                try await store.exportHistory(to: url)
                return (true, "Exported the usage history to \(url.lastPathComponent).")
            } catch {
                return (false, "Couldn't export: \(error.localizedDescription)")
            }
        case .historyImport(let url):
            do {
                return (true, try await store.importHistory(from: url).message)
            } catch {
                return (false, "Couldn't import \(url.lastPathComponent): it isn't a Netra usage history file.")
            }
        case .websitePromptToken:
            guard let token = services.prompt(
                title: "Website token",
                message: "Stored in Netra's own Keychain item and only sent to your endpoint.",
                initial: "", secure: true, confirm: "Save"
            ), !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return (false, "Cancelled.") }
            await store.saveWebsiteToken(token)
            return store.websiteTokenError.map { (false, $0) } ?? (true, "Token saved.")
        case .websitePromptEndpoint:
            guard let endpoint = services.prompt(
                title: "Website endpoint",
                message: "The site's usage ingest URL. Use https:// (http:// only for localhost).",
                initial: preferences.websiteEndpoint, secure: false, confirm: "Save"
            ) else { return (false, "Cancelled.") }
            return apply(.websiteEndpoint(endpoint.trimmingCharacters(in: .whitespacesAndNewlines)))
        case .websiteClearToken:
            await store.clearWebsiteToken()
            return store.websiteTokenError.map { (false, $0) } ?? (true, "Token removed.")
        case .websitePublishNow:
            await store.publishNow()
            return store.publishState?.lastError.map { (false, $0) } ?? (true, "Published.")
        }
    }

    /// Sets one preference, with the side effects the SwiftUI settings page
    /// runs when the same control changes.
    private func apply(_ change: DashboardPreferenceChange) -> (Bool, String) {
        let p = preferences
        switch change {
        case .menuBarIcon(let value): p.menuBarIcon = value
        case .menuBarItems(let value): p.menuBarItems = value
        case .menuBarStyle(let value): p.menuBarStyle = value
        case .menuBarTint(let value): p.menuBarTint = value
        case .menuBarLimitSource(let value): p.menuBarLimitSource = value
        case .menuBarCompact(let value): p.menuBarCompact = value
        case .showsLimits(let value): p.showsLimits = value
        case .showsProviderBreakdown(let value): p.showsProviderBreakdown = value
        case .showsActivityChart(let value): p.showsActivityChart = value
        case .showsKeepAwake(let value): p.showsKeepAwake = value
        case .hiddenMenuProviders(let value): p.hiddenMenuProviders = value
        case .defaultPeriod(let value): p.defaultPeriod = value
        case .barsShowRemaining(let value): p.barsShowRemaining = value
        case .resetTimeStyle(let value): p.resetTimeStyle = value
        case .showsPace(let value): p.showsPace = value
        case .limitProviderOrder(let value): p.limitProviderOrder = value
        case .claudeQuotaEnabled(let value):
            let changed = p.claudeQuotaEnabled != value
            p.claudeQuotaEnabled = value
            if changed, value { Task { await store.authorizeClaudeKeychain() } }
        case .cursorUsageEnabled(let value):
            let changed = p.cursorUsageEnabled != value
            p.cursorUsageEnabled = value
            if changed, value { Task { await store.refresh() } }
        case .confettiOnReset(let value): p.confettiOnReset = value
        case .notchIslandEnabled(let value): p.notchIslandEnabled = value
        case .dailyTokenAlertEnabled(let value): p.dailyTokenAlertEnabled = value
        case .dailyTokenAlertThreshold(let value): p.dailyTokenAlertThreshold = value
        case .providerLimitAlertEnabled(let value): p.providerLimitAlertEnabled = value
        case .providerLimitAlertThreshold(let value): p.providerLimitAlertThreshold = value
        case .websitePublishEnabled(let value):
            let changed = p.websitePublishEnabled != value
            p.websitePublishEnabled = value
            if changed {
                Task {
                    await store.websiteSettingsChanged()
                    if value { await store.publishNow() }
                }
            }
        case .websiteEndpoint(let value):
            let changed = p.websiteEndpoint != value
            p.websiteEndpoint = value
            if changed { Task { await store.websiteSettingsChanged() } }
            if !value.isEmpty, p.websiteEndpointURL == nil {
                return (true, "Saved, but use an https:// address (http:// only for localhost).")
            }
        }
        return (true, "Saved.")
    }
}

/// Writes the state file off the main actor, atomically, so the dashboard
/// never reads half a file.
actor DashboardStateWriter {
    private let log = Logger(subsystem: "com.sahabji0P.netra", category: "bridge")
    private var lastSequence = 0

    /// Writes unless a newer state already landed (tasks may arrive out of order).
    func write(_ data: Data, to url: URL, sequence: Int) {
        guard sequence > lastSequence else { return }
        lastSequence = sequence
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try data.write(to: url, options: .atomic)
        } catch {
            log.error("dashboard state not written: \(String(describing: error), privacy: .public)")
        }
    }
}
