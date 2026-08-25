import DictationCore
import Foundation

public struct ApplicationMonotonicClock: MonotonicClock {
    public init() {}

    public func now() -> MonotonicInstant {
        .init(nanoseconds: Int64(clamping: DispatchTime.now().uptimeNanoseconds))
    }
}

public actor ApplicationDeadlineScheduler: DictationDeadlineBoundary {
    public typealias EventHandler = @Sendable (DictationEvent) async -> Void

    private struct Key: Hashable {
        let id: DictationID
        let kind: DictationDeadlineKind
    }

    private struct ScheduledTask {
        let token: UUID
        let task: Task<Void, Never>
    }

    private let clock: any MonotonicClock
    private let onEvent: EventHandler
    private var tasks: [Key: ScheduledTask] = [:]

    public init(clock: any MonotonicClock, onEvent: @escaping EventHandler) {
        self.clock = clock
        self.onEvent = onEvent
    }

    public func schedule(
        _ kind: DictationDeadlineKind,
        for id: DictationID,
        at instant: MonotonicInstant
    ) {
        let key = Key(id: id, kind: kind)
        tasks[key]?.task.cancel()
        let token = UUID()
        let remaining = max(.zero, clock.now().duration(to: instant))
        let onEvent = onEvent
        let task = Task { [weak self] in
            do {
                try await Task.sleep(for: remaining)
                let event: DictationEvent = switch kind {
                case .recordingWarning: .recordingWarningFired(id)
                case .recordingLimit: .recordingLimitFired(id)
                case .watchdog: .watchdogFired(id)
                case .completion: .completionDeadlineFired(id)
                }
                await onEvent(event)
            } catch {
                // Replaced deadline or application shutdown.
            }
            await self?.removeTask(for: key, token: token)
        }
        tasks[key] = .init(token: token, task: task)
    }

    public func cancelAll() {
        tasks.values.forEach { $0.task.cancel() }
        tasks.removeAll()
    }

    private func removeTask(for key: Key, token: UUID) {
        guard tasks[key]?.token == token else { return }
        tasks.removeValue(forKey: key)
    }
}

public actor DictationEventRelay {
    private weak var coordinator: DictationCoordinator?

    public init() {}

    public func connect(_ coordinator: DictationCoordinator) {
        self.coordinator = coordinator
    }

    public func send(_ event: DictationEvent) async {
        await coordinator?.receive(event)
    }
}
