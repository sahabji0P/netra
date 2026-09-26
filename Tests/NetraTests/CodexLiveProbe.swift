import XCTest
@testable import Netra

/// Dev-only: asks the local Codex CLI's app server for live limits.
/// Runs only when NETRA_CODEX_LIVE is set.
final class CodexLiveProbe: XCTestCase {
    func testLiveCodexRateLimits() throws {
        guard ProcessInfo.processInfo.environment["NETRA_CODEX_LIVE"] != nil else {
            throw XCTSkip("set NETRA_CODEX_LIVE to query the local codex app-server")
        }
        let started = Date.now
        let quota = try XCTUnwrap(CodexLiveQuota.fetch(), "codex app-server gave no rate limits")
        print("CODEX live in \(Date.now.timeIntervalSince(started))s:",
              quota.windows.map { "\($0.label) \($0.usedPercent)% resets \($0.resetsAt.map(String.init(describing:)) ?? "-")" },
              "plan", quota.planType ?? "-", "credits", quota.resetCreditsAvailable ?? -1)
    }
}
