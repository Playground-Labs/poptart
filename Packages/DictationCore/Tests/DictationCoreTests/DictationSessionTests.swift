import Foundation
import XCTest
@testable import DictationCore

final class DictationSessionTests: XCTestCase {
    func testCleanedDictationIsInsertedAndRecorded() async {
        let clock = FakeMonotonicClock()
        let session = DictationSessionActor(clock: clock)
        let start = fixtureStart()

        let pressEffects = await session.handle(.press(start))
        XCTAssertTrue(pressEffects.contains(.startRecording(.init(
            id: start.id,
            personalVocabulary: start.personalVocabulary
        ))))

        _ = await session.handle(.release(start.id))
        clock.advance(by: .milliseconds(200))
        let recognitionEffects = await session.handle(.recognitionCompleted(
            start.id,
            .final(.init(text: "I think this looks good lets do a PR"))
        ))
        XCTAssertTrue(recognitionEffects.contains { effect in
            if case .requestCleanup = effect { true } else { false }
        })

        clock.advance(by: .milliseconds(300))
        let cleanupEffects = await session.handle(.cleanupCompleted(
            start.id,
            .cleaned(.init(
                text: "I think this looks good. Let's do a PR.",
                metadata: .init(changed: true, editCount: 3)
            ))
        ))
        XCTAssertTrue(cleanupEffects.contains { effect in
            if case .revalidateTarget = effect { true } else { false }
        })

        clock.advance(by: .milliseconds(20))
        let targetEffects = await session.handle(.targetRevalidated(start.id, .valid))
        XCTAssertTrue(targetEffects.contains { effect in
            if case .deliverToTarget(let request) = effect {
                return request.text == "I think this looks good. Let's do a PR."
            }
            return false
        })

        clock.advance(by: .milliseconds(20))
        let completionEffects = await session.handle(.deliveryCompleted(
            start.id,
            .inserted(.accessibility)
        ))
        XCTAssertTrue(completionEffects.contains { effect in
            if case .recordHistory(let intent) = effect {
                return intent.rawTranscript == "I think this looks good lets do a PR"
                    && intent.deliveredText == "I think this looks good. Let's do a PR."
                    && intent.cleanupChanged
                    && intent.outcome == .cleanedInsertion(
                        method: .accessibility,
                        recordingEnd: .released
                    )
            }
            return false
        })
    }

    func testRecognitionWatchdogDeliversLatestUsableHypothesisWithoutCleanup() async {
        let clock = FakeMonotonicClock()
        let session = DictationSessionActor(clock: clock)
        let start = fixtureStart()

        _ = await session.handle(.press(start))
        _ = await session.handle(.recognitionHypothesis(
            start.id,
            .init(text: "The latest usable words")
        ))
        _ = await session.handle(.release(start.id))
        clock.advance(by: .milliseconds(1_400))

        let effects = await session.handle(.watchdogFired(start.id))

        XCTAssertTrue(effects.contains(.cancelRecognition(start.id)))
        XCTAssertTrue(effects.contains { effect in
            if case .revalidateTarget = effect { return true }
            return false
        })
        XCTAssertFalse(effects.contains { effect in
            if case .requestCleanup = effect { return true }
            return false
        })
    }

    func testCancellationStopsActiveWorkWithoutCreatingHistory() async {
        let clock = FakeMonotonicClock()
        let session = DictationSessionActor(clock: clock)
        let start = fixtureStart()

        _ = await session.handle(.press(start))
        _ = await session.handle(.release(start.id))
        _ = await session.handle(.recognitionCompleted(
            start.id,
            .final(.init(text: "unfinished cleanup"))
        ))

        let effects = await session.handle(.cancel(start.id))
        let snapshot = await session.snapshot()

        XCTAssertTrue(effects.contains(.cancelCleanup(start.id)))
        XCTAssertTrue(effects.contains(.presentIndicator(.init(
            dictationID: start.id,
            state: .cancelled
        ))))
        XCTAssertFalse(effects.contains { effect in
            if case .recordHistory = effect { return true }
            return false
        })
        XCTAssertEqual(snapshot.outcome, .cancelled)
    }

    func testAutoRepeatAndDuplicateReleaseDoNotStartOrFinalizeTwice() async {
        let clock = FakeMonotonicClock()
        let session = DictationSessionActor(clock: clock)
        let start = fixtureStart()
        _ = await session.handle(.press(start))

        let repeatedPress = await session.handle(.press(start))
        XCTAssertEqual(repeatedPress, [])
        let firstRelease = await session.handle(.release(start.id))
        XCTAssertTrue(firstRelease.contains { if case .stopRecordingAndFinalize = $0 { true } else { false } })
        let duplicateRelease = await session.handle(.release(start.id))
        XCTAssertEqual(duplicateRelease, [])
    }

    func testLateResultFromPriorDictationCannotAffectRapidNextDictation() async {
        let clock = FakeMonotonicClock()
        let session = DictationSessionActor(clock: clock)
        let first = fixtureStart()
        _ = await session.handle(.press(first))
        _ = await session.handle(.release(first.id))
        _ = await session.handle(.cancel(first.id))

        let second = fixtureStart(id: .init())
        _ = await session.handle(.press(second))
        let lateEffects = await session.handle(.recognitionCompleted(
            first.id,
            .final(.init(text: "private text from the old Dictation"))
        ))
        let snapshot = await session.snapshot()

        XCTAssertEqual(lateEffects, [])
        XCTAssertEqual(snapshot.activeID, second.id)
        XCTAssertEqual(snapshot.phase, .recording)
    }

    func testCompletionPresentationReturnsSessionToReady() async {
        let clock = FakeMonotonicClock()
        let session = DictationSessionActor(clock: clock)
        let start = fixtureStart()
        _ = await session.handle(.press(start))
        _ = await session.handle(.cancel(start.id))

        let effects = await session.handle(.completionPresentationElapsed(start.id))
        let snapshot = await session.snapshot()

        XCTAssertEqual(effects, [.presentIndicator(.init(dictationID: nil, state: .ready))])
        XCTAssertEqual(snapshot, .init(phase: .ready, activeID: nil, outcome: nil))
    }
}

private final class FakeMonotonicClock: MonotonicClock, @unchecked Sendable {
    private var instant = MonotonicInstant.zero

    func now() -> MonotonicInstant { instant }

    func advance(by duration: Duration) {
        instant = instant.advanced(by: duration)
    }
}

private func fixtureStart(id: DictationID = .init()) -> DictationStart {
    DictationStart(
        id: id,
        occurredAt: Date(timeIntervalSince1970: 1_800_000_000),
        target: InsertionTarget(
            applicationIdentifier: "com.example.Editor",
            elementIdentifier: "editor-1",
            selection: nil
        ),
        targetContext: TargetContext(
            applicationIdentifier: "com.example.Editor",
            applicationCategory: .textEditor,
            textBeforeCursor: "",
            textAfterCursor: "",
            selectedText: nil
        ),
        personalVocabulary: PersonalVocabulary(entries: ["Poptart"])
    )
}
