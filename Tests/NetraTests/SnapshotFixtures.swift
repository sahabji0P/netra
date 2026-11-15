import Foundation
@testable import Netra

extension UsageSnapshot {
    /// A snapshot the way a refresh builds one, from an empty usage history:
    /// the report's daily rows and Cursor's events are recorded, and weeks
    /// and months are summed from the recorded days.
    init(
        fetchedAt: Date, report: CCUnifiedReport, activeBlock: BlockStat?,
        codexQuota: CodexQuota?, claudeQuota: ClaudeQuota?, cursorQuota: CursorQuota? = nil,
        cursorEvents: [CursorUsageEvent] = [], calendar: Calendar = .current
    ) {
        var history = UsageHistory()
        history.record(report, cursorEvents: cursorEvents, calendar: calendar)
        self.init(
            fetchedAt: fetchedAt, daily: history.rows(calendar: calendar), activeBlock: activeBlock,
            codexQuota: codexQuota, claudeQuota: claudeQuota, cursorQuota: cursorQuota, calendar: calendar
        )
    }
}
