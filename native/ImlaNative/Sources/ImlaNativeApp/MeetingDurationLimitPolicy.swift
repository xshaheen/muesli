import Foundation

enum MeetingDurationLimitPolicy {
    static let maximumDuration: TimeInterval = 3 * 60 * 60
    static let warningLeadTime: TimeInterval = 5 * 60

    static func warningDate(startedAt: Date) -> Date {
        startedAt.addingTimeInterval(maximumDuration - warningLeadTime)
    }

    static func stopDate(startedAt: Date) -> Date {
        startedAt.addingTimeInterval(maximumDuration)
    }
}
