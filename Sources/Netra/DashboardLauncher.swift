import AppKit
import os

/// The pages of Netra's main window, as the popover and the island name
/// them when they open it.
enum DashboardSection: String, CaseIterable, Identifiable, Sendable {
    case usage
    case subscriptions
    case menuBar
    case limits
    case providers
    case accounts
    case notifications
    case general

    var id: Self { self }
}

/// Opens Netra's main window: the GPUI app that ships beside Netra
/// (`Contents/Helpers/Netra Dashboard.app`), or the binary
/// `NETRA_DASHBOARD_BIN` names in a development build.
@MainActor
final class DashboardLauncher {
    static let shared = DashboardLauncher()
    static let bundleIdentifier = "com.sahabji0P.netra.dashboard"

    /// Set by the bridge so an open window can be sent to a page.
    weak var bridge: DashboardBridge?

    private var launchedProcess: Process?
    private let log = Logger(subsystem: "com.sahabji0P.netra", category: "dashboard")

    enum Target: Equatable {
        case bundle(URL)
        case binary(URL)
    }

    /// Where the GPUI dashboard lives, if this build has one.
    static func locate(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        mainBundle: URL = Bundle.main.bundleURL,
        fileManager: FileManager = .default
    ) -> Target? {
        if let path = environment["NETRA_DASHBOARD_BIN"], !path.isEmpty {
            let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
            if fileManager.isExecutableFile(atPath: url.path) { return .binary(url) }
        }
        let nested = mainBundle.appendingPathComponent("Contents/Helpers/Netra Dashboard.app", isDirectory: true)
        if fileManager.fileExists(atPath: nested.appendingPathComponent("Contents/Info.plist").path) {
            return .bundle(nested)
        }
        return nil
    }

    /// Shows `section` in the main window, starting it when it is not
    /// running. A build without the window says so instead of doing nothing.
    func open(_ section: DashboardSection) {
        guard let target = Self.locate() else {
            explainMissingWindow()
            return
        }
        let page = section.bridgePageID
        if case .binary = target, let process = launchedProcess, process.isRunning {
            // Started by us; it may not have registered as an app yet.
            bridge?.navigate(to: page)
            NSRunningApplication(processIdentifier: process.processIdentifier)?.activate()
            return
        }
        if let running = runningApp(for: target) {
            bridge?.navigate(to: page)
            if case .bundle(let url) = target {
                // Activation from an inactive app is only a request on
                // macOS 14; opening the running app raises it reliably.
                let configuration = NSWorkspace.OpenConfiguration()
                configuration.activates = true
                NSWorkspace.shared.openApplication(at: url, configuration: configuration) { _, _ in }
            } else {
                running.activate()
            }
            return
        }
        switch target {
        case .bundle(let url):
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.arguments = ["--page", page]
            configuration.activates = true
            NSWorkspace.shared.openApplication(at: url, configuration: configuration) { [log] _, error in
                if let error {
                    log.error("dashboard did not open: \(String(describing: error), privacy: .public)")
                }
            }
        case .binary(let url):
            let process = Process()
            process.executableURL = url
            process.arguments = ["--page", page]
            do {
                try process.run()
                launchedProcess = process
            } catch {
                log.error("dashboard binary did not start: \(String(describing: error), privacy: .public)")
                explainMissingWindow()
            }
        }
    }

    /// Closes the window if it is open. Called when Netra quits.
    func closeWindow() {
        if let process = launchedProcess, process.isRunning { process.terminate() }
        for app in NSRunningApplication.runningApplications(withBundleIdentifier: Self.bundleIdentifier) {
            app.terminate()
        }
    }

    /// Only a build assembled without the Rust toolchain lacks the window;
    /// releases refuse to build that way.
    private func explainMissingWindow() {
        log.error("the GPUI dashboard is missing from this build")
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Netra's window is missing from this build"
        alert.informativeText = "Reinstall Netra, or rebuild it with Rust installed (scripts/build-app.sh)."
        alert.runModal()
    }

    private func runningApp(for target: Target) -> NSRunningApplication? {
        switch target {
        case .bundle:
            return NSRunningApplication.runningApplications(withBundleIdentifier: Self.bundleIdentifier)
                .first { !$0.isTerminated }
        case .binary(let url):
            let path = url.resolvingSymlinksInPath().path
            return NSWorkspace.shared.runningApplications.first {
                !$0.isTerminated && $0.executableURL?.resolvingSymlinksInPath().path == path
            }
        }
    }
}

extension DashboardSection {
    /// The page id the GPUI dashboard uses for this section.
    var bridgePageID: String {
        switch self {
        case .usage: "usage"
        case .subscriptions: "subscriptions"
        case .menuBar: "menubar"
        case .limits: "limits"
        case .providers: "providers"
        case .accounts: "accounts"
        case .notifications: "notifications"
        case .general: "general"
        }
    }

    init?(bridgePageID: String) {
        guard let section = DashboardSection.allCases.first(where: { $0.bridgePageID == bridgePageID }) else {
            return nil
        }
        self = section
    }
}
