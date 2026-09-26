import Foundation
import IOKit.pwr_mgt
import Observation
import os

/// Holds (and releases) an IOKit power assertion that prevents idle system
/// sleep. The display is still allowed to sleep — agents keep running with the
/// screen dark. Closing the lid or choosing Sleep explicitly still sleeps the
/// Mac; the assertion only blocks *idle* sleep. Assertions are released
/// automatically by the OS if the process dies, so the failure mode is always
/// "Mac sleeps normally".
@MainActor
@Observable
final class AwakeController {
    enum Mode: Equatable {
        case off
        case indefinite
        case until(Date)
    }

    private(set) var mode: Mode = .off
    private var assertionID: IOPMAssertionID = 0
    private var expiryTask: Task<Void, Never>?
    private let log = Logger(subsystem: "com.sahabji0P.netra", category: "awake")

    var isAwake: Bool { mode != .off }

    func setAwake(_ on: Bool) {
        on ? hold(.indefinite) : release()
    }

    func hold(for duration: TimeInterval) {
        hold(.until(Date.now.addingTimeInterval(duration)))
    }

    private func hold(_ newMode: Mode) {
        expiryTask?.cancel()
        expiryTask = nil

        if assertionID == 0 {
            var id: IOPMAssertionID = 0
            let result = IOPMAssertionCreateWithName(
                kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
                IOPMAssertionLevel(kIOPMAssertionLevelOn),
                "Netra is keeping the Mac awake" as CFString,
                &id
            )
            guard result == kIOReturnSuccess else {
                log.error("IOPMAssertionCreateWithName failed: \(result)")
                return
            }
            assertionID = id
        }
        mode = newMode

        if case .until(let date) = newMode {
            expiryTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(date.timeIntervalSinceNow))
                guard !Task.isCancelled else { return }
                self?.release()
            }
        }
    }

    func release() {
        expiryTask?.cancel()
        expiryTask = nil
        if assertionID != 0 {
            IOPMAssertionRelease(assertionID)
            assertionID = 0
        }
        mode = .off
    }

    /// Locks the screen immediately, then puts the Mac to sleep. Releases any
    /// held assertion first. Locking uses the same login-framework call the
    /// system's own ctrl-cmd-Q shortcut goes through; if that ever fails the
    /// Mac still sleeps, and whether it wakes locked then depends on the
    /// user's "require password after sleep" setting.
    func lockAndSleep() {
        release()
        if !Self.lockScreen() {
            log.error("screen lock unavailable; falling back to sleep only")
        }
        // Give loginwindow a beat to put the lock up before sleeping, so the
        // wake never flashes the unlocked desktop.
        Task { [log] in
            try? await Task.sleep(for: .milliseconds(500))
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
            process.arguments = ["sleepnow"]
            do {
                try process.run()
            } catch {
                log.error("pmset sleepnow failed to launch: \(error.localizedDescription)")
            }
        }
    }

    /// `SACLockScreenImmediate` is the only way to lock the screen on modern
    /// macOS without Accessibility permission (CGSession was removed). It is
    /// resolved dynamically so a future macOS that drops it degrades to
    /// sleep-only instead of crashing.
    private static func lockScreen() -> Bool {
        guard let handle = dlopen(
            "/System/Library/PrivateFrameworks/login.framework/Versions/Current/login",
            RTLD_NOW
        ), let symbol = dlsym(handle, "SACLockScreenImmediate") else { return false }
        typealias LockFunction = @convention(c) () -> Int32
        _ = unsafeBitCast(symbol, to: LockFunction.self)()
        return true
    }
}
