import Foundation

/// An opaque reading from the application's monotonic time source.
public struct MonotonicInstant: Hashable, Comparable, Sendable {
    public static let zero = Self(nanoseconds: 0)

    public let nanoseconds: Int64

    public init(nanoseconds: Int64) {
        self.nanoseconds = nanoseconds
    }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.nanoseconds < rhs.nanoseconds
    }

    public func advanced(by duration: Duration) -> Self {
        let components = duration.components
        let seconds = components.seconds.multipliedReportingOverflow(by: 1_000_000_000)
        precondition(!seconds.overflow, "Duration is outside the supported monotonic range")
        let subsecondNanoseconds = components.attoseconds / 1_000_000_000
        let total = seconds.partialValue.addingReportingOverflow(subsecondNanoseconds)
        precondition(!total.overflow, "Duration is outside the supported monotonic range")
        let result = nanoseconds.addingReportingOverflow(total.partialValue)
        precondition(!result.overflow, "Monotonic instant is outside the supported range")
        return Self(nanoseconds: result.partialValue)
    }

    public func duration(to later: Self) -> Duration {
        .nanoseconds(later.nanoseconds - nanoseconds)
    }
}

public protocol MonotonicClock: Sendable {
    func now() -> MonotonicInstant
}

public struct DictationPolicy: Equatable, Sendable {
    public var watchdogDelay: Duration
    public var completionDeadline: Duration
    public var recordingWarningDelay: Duration
    public var recordingLimit: Duration

    public init(
        watchdogDelay: Duration = .milliseconds(1_400),
        completionDeadline: Duration = .milliseconds(1_500),
        recordingWarningDelay: Duration = .seconds(270),
        recordingLimit: Duration = .seconds(300)
    ) {
        precondition(watchdogDelay > .zero)
        precondition(completionDeadline >= watchdogDelay)
        precondition(recordingWarningDelay > .zero)
        precondition(recordingLimit >= recordingWarningDelay)
        self.watchdogDelay = watchdogDelay
        self.completionDeadline = completionDeadline
        self.recordingWarningDelay = recordingWarningDelay
        self.recordingLimit = recordingLimit
    }
}
