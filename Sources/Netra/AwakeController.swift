import Foundation
import IOKit.pwr_mgt
import Observation

/// Holds (and releases) an IOKit power assertion that prevents idle system
/// sleep. The display is still allowed to sleep — agents keep running with the
/// screen dark. Assertions are released automatically by the OS if the process
/// dies, so the failure mode is always "Mac sleeps normally".
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

    var isAwake: Bool { mode != .off }

    var statusText: String {
        switch mode {
        case .off: "Mac sleeps normally"
        case .indefinite: "Held awake until you turn it off"
        case .until(let date): "Held awake until \(date.formatted(date: .omitted, time: .shortened))"
        }
    }

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
            guard result == kIOReturnSuccess else { return }
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

    /// Locks the screen (sleep does this when a password is required) and puts
    /// the Mac to sleep immediately. Releases any held assertion first.
    func lockAndSleep() {
        release()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        process.arguments = ["sleepnow"]
        try? process.run()
    }
}
