import Foundation
import ServiceManagement

/// SMAppService only works from a real .app bundle; when running the bare
/// SwiftPM executable during development the toggle is hidden.
enum LaunchAtLogin {
    static var isAvailable: Bool {
        Bundle.main.bundlePath.hasSuffix(".app")
    }

    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    static func set(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            // Non-fatal: the toggle re-reads actual status, so a failure
            // simply leaves the switch where the system says it is.
        }
    }
}
