import Foundation
import Testing
@testable import MuesliNativeApp

@Suite("Meeting duration limit")
struct MeetingDurationLimitTests {
    private let startedAt = Date(timeIntervalSince1970: 1_800_000_000)

    @Test("warns five minutes before the three-hour recording limit")
    func warningDeadline() {
        #expect(MeetingDurationLimitPolicy.maximumDuration == 3 * 60 * 60)
        #expect(MeetingDurationLimitPolicy.warningLeadTime == 5 * 60)
        #expect(
            MeetingDurationLimitPolicy.warningDate(startedAt: startedAt)
                == startedAt.addingTimeInterval(2 * 60 * 60 + 55 * 60)
        )
    }

    @Test("stops at three hours regardless of meeting source")
    func stopDeadline() {
        #expect(
            MeetingDurationLimitPolicy.stopDate(startedAt: startedAt)
                == startedAt.addingTimeInterval(3 * 60 * 60)
        )
    }
}
