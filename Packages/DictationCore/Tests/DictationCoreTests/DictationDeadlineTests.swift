import Foundation
import XCTest
@testable import DictationCore

final class DictationDeadlineTests: XCTestCase {
    func testCleanupResultImmediatelyBeforeWatchdogIsAccepted() async {
        let (session, clock, start) = await cleaningSession()
        clock.advance(by: .nanoseconds(1_399_999_999))

        let effects = await session.handle(.cleanupCompleted(
            start.id,
            .cleaned(.init(text: "Accepted.", metadata: .init(changed: true, editCount: 1)))
        ))

        XCTAssertTrue(effects.contains { if case .revalidateTarget = $0 { true } else { false } })
        XCTAssertFalse(effects.contains(.cancelCleanup(start.id)))
    }

    func testCleanupResultAtWatchdogFallsBackToRawTranscript() async {
        let (session, clock, start) = await cleaningSession()
        clock.advance(by: .milliseconds(1_400))

        let effects = await session.handle(.cleanupCompleted(
            start.id,
            .cleaned(.init(text: "Too late.", metadata: .init(changed: true, editCount: 1)))
        ))

        XCTAssertTrue(effects.contains(.cancelCleanup(start.id)))
        _ = await session.handle(.targetRevalidated(start.id, .valid))
        let delivery = await session.handle(.deliveryCompleted(start.id, .inserted(.accessibility)))
        XCTAssertTrue(delivery.contains { effect in
            if case .recordHistory(let record) = effect {
                return record.deliveredText == "Raw words"
                    && record.outcome == .rawTranscriptFallback(
                        reason: .cleanupTimedOut,
                        method: .accessibility,
                        recordingEnd: .released
                    )
            }
            return false
        })
    }

    func testCleanupResultAfterWatchdogAlsoFallsBack() async {
        let (session, clock, start) = await cleaningSession()
        clock.advance(by: .nanoseconds(1_400_000_001))

        let effects = await session.handle(.cleanupCompleted(
            start.id,
            .cleaned(.init(text: "Too late.", metadata: .init(changed: true, editCount: 1)))
        ))

        XCTAssertTrue(effects.contains(.cancelCleanup(start.id)))
    }

    func testDeliveryAtPublicDeadlineIsAccepted() async {
        let (session, clock, start) = await deliveringSession()
        clock.advance(by: .milliseconds(1_500))

        _ = await session.handle(.deliveryCompleted(start.id, .inserted(.accessibility)))
        let outcome = await awaitOutcome(session)

        XCTAssertEqual(
            outcome,
            .cleanedInsertion(method: .accessibility, recordingEnd: .released)
        )
    }

    func testUnfinishedDeliveryAtPublicDeadlineFailsExplicitly() async {
        let (session, clock, start) = await deliveringSession()
        clock.advance(by: .milliseconds(1_500))

        let effects = await session.handle(.completionDeadlineFired(start.id))
        let outcome = await awaitOutcome(session)

        XCTAssertTrue(effects.contains(.cancelDelivery(start.id)))
        XCTAssertEqual(
            outcome,
            .deliveryFailure(
                source: .cleaned,
                reason: .completionDeadlineExceeded,
                recordingEnd: .released
            )
        )
    }

    func testDeliveryImmediatelyAfterPublicDeadlineCannotReportSuccess() async {
        let (session, clock, start) = await deliveringSession()
        clock.advance(by: .nanoseconds(1_500_000_001))

        let effects = await session.handle(.deliveryCompleted(start.id, .inserted(.accessibility)))
        let outcome = await awaitOutcome(session)

        XCTAssertTrue(effects.contains(.cancelDelivery(start.id)))
        XCTAssertEqual(
            outcome,
            .deliveryFailure(
                source: .cleaned,
                reason: .completionDeadlineExceeded,
                recordingEnd: .released
            )
        )
    }

    func testRecordingLimitDoesNotFireImmediatelyBeforeFiveMinutes() async {
        let clock = DeadlineFakeClock()
        let session = DictationSessionActor(clock: clock)
        let start = deadlineStart()
        _ = await session.handle(.press(start))
        clock.advance(by: .nanoseconds(299_999_999_999))

        let effects = await session.handle(.recordingLimitFired(start.id))
        let phase = await awaitSnapshotPhase(session)

        XCTAssertEqual(effects, [])
        XCTAssertEqual(phase, .recording)
    }
}

private final class DeadlineFakeClock: MonotonicClock, @unchecked Sendable {
    private var instant = MonotonicInstant.zero
    func now() -> MonotonicInstant { instant }
    func advance(by duration: Duration) { instant = instant.advanced(by: duration) }
}

private func deadlineStart() -> DictationStart {
    .init(
        id: .init(),
        occurredAt: Date(timeIntervalSince1970: 1_800_000_000),
        target: .init(
            applicationIdentifier: "com.example.Editor",
            elementIdentifier: "editor-1",
            selection: nil
        ),
        targetContext: .init(
            applicationIdentifier: "com.example.Editor",
            applicationCategory: .textEditor,
            textBeforeCursor: "",
            textAfterCursor: "",
            selectedText: nil
        ),
        personalVocabulary: .init(entries: [])
    )
}

private func cleaningSession() async -> (DictationSessionActor, DeadlineFakeClock, DictationStart) {
    let clock = DeadlineFakeClock()
    let session = DictationSessionActor(clock: clock)
    let start = deadlineStart()
    _ = await session.handle(.press(start))
    _ = await session.handle(.release(start.id))
    _ = await session.handle(.recognitionCompleted(
        start.id,
        .final(.init(text: "Raw words"))
    ))
    return (session, clock, start)
}

private func deliveringSession() async -> (DictationSessionActor, DeadlineFakeClock, DictationStart) {
    let (session, clock, start) = await cleaningSession()
    _ = await session.handle(.cleanupCompleted(
        start.id,
        .cleaned(.init(text: "Clean words.", metadata: .init(changed: true, editCount: 1)))
    ))
    _ = await session.handle(.targetRevalidated(start.id, .valid))
    return (session, clock, start)
}

private func awaitOutcome(_ session: DictationSessionActor) async -> DictationOutcome? {
    await session.snapshot().outcome
}

private func awaitSnapshotPhase(_ session: DictationSessionActor) async -> DictationPhase {
    await session.snapshot().phase
}
