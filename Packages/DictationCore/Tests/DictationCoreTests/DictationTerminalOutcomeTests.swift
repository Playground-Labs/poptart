import Foundation
import XCTest
@testable import DictationCore

final class DictationTerminalOutcomeTests: XCTestCase {
    func testSecureTargetIsRejectedBeforeRecordingAndNeverCreatesHistory() async {
        let session = DictationSessionActor(clock: OutcomeFakeClock())
        let start = outcomeFixtureStart(secure: true)

        let effects = await session.handle(.press(start))
        let snapshot = await session.snapshot()

        XCTAssertEqual(snapshot.outcome, .secureTargetRejection)
        XCTAssertEqual(effects, [.presentIndicator(.init(
            dictationID: start.id,
            state: .unavailableSecureTarget
        ))])
    }

    func testCleanupFailureInsertsRawTranscript() async {
        let clock = OutcomeFakeClock()
        let session = DictationSessionActor(clock: clock)
        let start = outcomeFixtureStart()
        await reachCleanup(session, start: start, rawTranscript: "Raw words")

        _ = await session.handle(.cleanupCompleted(
            start.id,
            .rawTranscriptFallback(.unsafeEditPlan)
        ))
        _ = await session.handle(.targetRevalidated(start.id, .valid))
        let effects = await session.handle(.deliveryCompleted(
            start.id,
            .inserted(.clipboardPaste)
        ))

        XCTAssertTrue(effects.contains { effect in
            if case .recordHistory(let record) = effect {
                return record.deliveredText == "Raw words"
                    && record.outcome == .rawTranscriptFallback(
                        reason: .unsafeEditPlan,
                        method: .clipboardPaste,
                        recordingEnd: .released
                    )
            }
            return false
        })
        XCTAssertTrue(effects.contains(.presentIndicator(.init(
            dictationID: start.id,
            state: .rawTranscriptFallback
        ))))
    }

    func testOversizedDeterministicResultHasExplicitOutcome() async {
        let clock = OutcomeFakeClock()
        let session = DictationSessionActor(clock: clock)
        let start = outcomeFixtureStart()
        await reachCleanup(session, start: start, rawTranscript: "CR I mean PR")

        _ = await session.handle(.cleanupCompleted(
            start.id,
            .oversizedDeterministic(.init(
                text: "PR",
                metadata: .init(changed: true, editCount: 1)
            ))
        ))
        _ = await session.handle(.targetRevalidated(start.id, .valid))
        let effects = await session.handle(.deliveryCompleted(start.id, .inserted(.accessibility)))

        let outcome = await session.snapshot().outcome
        XCTAssertEqual(
            outcome,
            .oversizedDeterministicFallback(
                method: .accessibility,
                recordingEnd: .released
            )
        )
        XCTAssertTrue(effects.contains(.presentIndicator(.init(
            dictationID: start.id,
            state: .oversizedFallback
        ))))
        XCTAssertTrue(effects.contains { if case .recordHistory = $0 { true } else { false } })
    }

    func testChangedTargetCopiesResultInsteadOfInserting() async {
        let clock = OutcomeFakeClock()
        let session = DictationSessionActor(clock: clock)
        let start = outcomeFixtureStart(selection: .init(location: 4, length: 8))
        await reachCleanup(session, start: start, rawTranscript: "replacement")
        _ = await session.handle(.cleanupCompleted(
            start.id,
            .cleaned(.init(text: "Replacement.", metadata: .init(changed: true, editCount: 2)))
        ))

        let targetEffects = await session.handle(.targetRevalidated(start.id, .changed))
        XCTAssertTrue(targetEffects.contains { effect in
            if case .copyToClipboard(let request) = effect {
                return request.text == "Replacement."
            }
            return false
        })
        XCTAssertFalse(targetEffects.contains { effect in
            if case .deliverToTarget = effect { return true }
            return false
        })

        let completionEffects = await session.handle(.deliveryCompleted(start.id, .copiedToClipboard))
        let outcome = await session.snapshot().outcome
        XCTAssertEqual(
            outcome,
            .targetChangedClipboard(source: .cleaned, recordingEnd: .released)
        )
        XCTAssertTrue(completionEffects.contains(.presentIndicator(.init(
            dictationID: start.id,
            state: .copiedBecauseTargetChanged
        ))))
        XCTAssertTrue(completionEffects.contains { if case .recordHistory = $0 { true } else { false } })
    }

    func testNoTargetDictationRecordsThenCopiesWithoutRevalidatingAnyTarget() async {
        let clock = OutcomeFakeClock()
        let session = DictationSessionActor(clock: clock)
        let start = outcomeFixtureStart(noTarget: true)

        let pressEffects = await session.handle(.press(start))
        XCTAssertTrue(pressEffects.contains(.startRecording(.init(
            id: start.id,
            personalVocabulary: start.personalVocabulary
        ))))
        XCTAssertTrue(pressEffects.contains(.presentIndicator(.init(
            dictationID: start.id,
            state: .recording(audioActivity: nil)
        ))))

        _ = await session.handle(.release(start.id))
        _ = await session.handle(.recognitionCompleted(
            start.id,
            .final(.init(text: "no field here"))
        ))
        let deliveryEffects = await session.handle(.cleanupCompleted(
            start.id,
            .cleaned(.init(text: "No field here.", metadata: .init(changed: true, editCount: 1)))
        ))

        XCTAssertFalse(deliveryEffects.contains { effect in
            if case .revalidateTarget = effect { return true }
            return false
        })
        XCTAssertTrue(deliveryEffects.contains { effect in
            if case .copyToClipboard(let request) = effect {
                return request.text == "No field here."
            }
            return false
        })

        let completionEffects = await session.handle(.deliveryCompleted(
            start.id,
            .copiedToClipboard
        ))
        let outcome = await session.snapshot().outcome
        XCTAssertEqual(
            outcome,
            .noTargetClipboard(source: .cleaned, recordingEnd: .released)
        )
        XCTAssertTrue(completionEffects.contains(.presentIndicator(.init(
            dictationID: start.id,
            state: .copiedBecauseNoTarget
        ))))
        XCTAssertTrue(completionEffects.contains { effect in
            if case .recordHistory(let record) = effect {
                return record.deliveredText == "No field here."
                    && record.rawTranscript == "no field here"
                    && record.destinationApplicationIdentifier == "com.example.Editor"
            }
            return false
        })
    }

    func testEmptyFinalRecognitionProducesFailureWithoutDelivery() async {
        let clock = OutcomeFakeClock()
        let session = DictationSessionActor(clock: clock)
        let start = outcomeFixtureStart()
        _ = await session.handle(.press(start))
        _ = await session.handle(.release(start.id))

        let effects = await session.handle(.recognitionCompleted(
            start.id,
            .final(.init(text: "  \n "))
        ))

        let outcome = await session.snapshot().outcome
        XCTAssertEqual(
            outcome,
            .emptyRecognitionFailure(recordingEnd: .released)
        )
        XCTAssertFalse(effects.contains { effect in
            switch effect {
            case .deliverToTarget, .copyToClipboard: return true
            default: return false
            }
        })
    }

    func testOnlyFillerCleanupCompletesWithoutDeliveringEmptyText() async {
        let clock = OutcomeFakeClock()
        let session = DictationSessionActor(clock: clock)
        let start = outcomeFixtureStart()
        await reachCleanup(session, start: start, rawTranscript: "um uh")

        let effects = await session.handle(.cleanupCompleted(
            start.id,
            .cleaned(.init(text: " ", metadata: .init(changed: true, editCount: 1)))
        ))

        let outcome = await session.snapshot().outcome
        XCTAssertEqual(
            outcome,
            .emptyRecognitionFailure(recordingEnd: .released)
        )
        XCTAssertFalse(effects.contains { effect in
            switch effect {
            case .deliverToTarget, .copyToClipboard, .revalidateTarget: return true
            default: return false
            }
        })
        XCTAssertTrue(effects.contains { effect in
            if case .recordHistory(let record) = effect {
                return record.rawTranscript == "um uh" && record.deliveredText == nil
            }
            return false
        })
    }

    func testRecognitionHypothesisFallbackIsRecordedAsHypothesisNotRawTranscript() async {
        let clock = OutcomeFakeClock()
        let session = DictationSessionActor(clock: clock)
        let start = outcomeFixtureStart()
        _ = await session.handle(.press(start))
        _ = await session.handle(.recognitionHypothesis(start.id, .init(text: "Useful partial")))
        _ = await session.handle(.release(start.id))
        clock.advance(by: .milliseconds(1_400))
        _ = await session.handle(.watchdogFired(start.id))
        _ = await session.handle(.targetRevalidated(start.id, .valid))
        let effects = await session.handle(.deliveryCompleted(start.id, .inserted(.accessibility)))

        XCTAssertTrue(effects.contains { effect in
            if case .recordHistory(let record) = effect {
                return record.rawTranscript == nil
                    && record.deliveredText == "Useful partial"
                    && record.outcome == .recognitionHypothesisFallback(
                        method: .accessibility,
                        recordingEnd: .released
                    )
            }
            return false
        })
        XCTAssertTrue(effects.contains(.presentIndicator(.init(
            dictationID: start.id,
            state: .recognitionFallback
        ))))
    }

    func testFailedRecognitionBeforeWatchdogInsertsLatestHypothesis() async {
        let clock = OutcomeFakeClock()
        let session = DictationSessionActor(clock: clock)
        let start = outcomeFixtureStart()
        _ = await session.handle(.press(start))
        _ = await session.handle(.recognitionHypothesis(start.id, .init(text: "Useful partial")))
        _ = await session.handle(.release(start.id))
        clock.advance(by: .milliseconds(200))

        let recognitionEffects = await session.handle(.recognitionCompleted(
            start.id,
            .failed(.finalizationFailed)
        ))

        XCTAssertTrue(recognitionEffects.contains { effect in
            if case .revalidateTarget(let request) = effect { return request.id == start.id }
            return false
        })
        XCTAssertFalse(recognitionEffects.contains { effect in
            if case .requestCleanup = effect { return true }
            return false
        })

        let targetEffects = await session.handle(.targetRevalidated(start.id, .valid))
        XCTAssertTrue(targetEffects.contains { effect in
            if case .deliverToTarget(let request) = effect {
                return request.text == "Useful partial"
            }
            return false
        })

        let effects = await session.handle(.deliveryCompleted(start.id, .inserted(.accessibility)))
        let outcome = await session.snapshot().outcome
        XCTAssertEqual(
            outcome,
            .recognitionHypothesisFallback(method: .accessibility, recordingEnd: .released)
        )
        XCTAssertTrue(effects.contains { effect in
            if case .recordHistory(let record) = effect {
                return record.rawTranscript == nil
                    && record.deliveredText == "Useful partial"
                    && record.outcome == .recognitionHypothesisFallback(
                        method: .accessibility,
                        recordingEnd: .released
                    )
            }
            return false
        })
        XCTAssertTrue(effects.contains(.presentIndicator(.init(
            dictationID: start.id,
            state: .recognitionFallback
        ))))
    }

    func testFailedRecognitionWithoutUsableHypothesisCompletesWithoutText() async {
        let clock = OutcomeFakeClock()
        let session = DictationSessionActor(clock: clock)
        let start = outcomeFixtureStart()
        _ = await session.handle(.press(start))
        _ = await session.handle(.recognitionHypothesis(start.id, .init(text: "  \n ")))
        _ = await session.handle(.release(start.id))
        clock.advance(by: .milliseconds(200))

        let effects = await session.handle(.recognitionCompleted(
            start.id,
            .failed(.finalizationFailed)
        ))

        let outcome = await session.snapshot().outcome
        XCTAssertEqual(outcome, .emptyRecognitionFailure(recordingEnd: .released))
        XCTAssertFalse(effects.contains { effect in
            switch effect {
            case .deliverToTarget, .copyToClipboard, .revalidateTarget: return true
            default: return false
            }
        })
        XCTAssertTrue(effects.contains(.presentIndicator(.init(
            dictationID: start.id,
            state: .failure(.noUsableText)
        ))))
    }

    func testBlankOversizedDeterministicCleanupCompletesWithoutDeliveringEmptyText() async {
        let clock = OutcomeFakeClock()
        let session = DictationSessionActor(clock: clock)
        let start = outcomeFixtureStart()
        await reachCleanup(session, start: start, rawTranscript: "um uh")

        let effects = await session.handle(.cleanupCompleted(
            start.id,
            .oversizedDeterministic(.init(
                text: " \n ",
                metadata: .init(changed: true, editCount: 1)
            ))
        ))

        let outcome = await session.snapshot().outcome
        XCTAssertEqual(outcome, .emptyRecognitionFailure(recordingEnd: .released))
        XCTAssertFalse(effects.contains { effect in
            switch effect {
            case .deliverToTarget, .copyToClipboard, .revalidateTarget: return true
            default: return false
            }
        })
        XCTAssertTrue(effects.contains { effect in
            if case .recordHistory(let record) = effect {
                return record.rawTranscript == "um uh" && record.deliveredText == nil
            }
            return false
        })
    }

    func testNoHypothesisAtRecognitionWatchdogProducesEmptyFailure() async {
        let clock = OutcomeFakeClock()
        let session = DictationSessionActor(clock: clock)
        let start = outcomeFixtureStart()
        _ = await session.handle(.press(start))
        _ = await session.handle(.release(start.id))
        clock.advance(by: .milliseconds(1_400))

        let effects = await session.handle(.watchdogFired(start.id))

        XCTAssertTrue(effects.contains(.cancelRecognition(start.id)))
        let outcome = await session.snapshot().outcome
        XCTAssertEqual(
            outcome,
            .emptyRecognitionFailure(recordingEnd: .released)
        )
    }

    func testDeliveryFailureIsExplicitAndDoesNotClaimTextWasDelivered() async {
        let clock = OutcomeFakeClock()
        let session = DictationSessionActor(clock: clock)
        let start = outcomeFixtureStart()
        await reachCleanup(session, start: start, rawTranscript: "Raw")
        _ = await session.handle(.cleanupCompleted(
            start.id,
            .rawTranscriptFallback(.modelUnavailable)
        ))
        _ = await session.handle(.targetRevalidated(start.id, .valid))

        let effects = await session.handle(.deliveryCompleted(
            start.id,
            .failed(.pasteTimedOut)
        ))

        XCTAssertTrue(effects.contains { effect in
            if case .recordHistory(let record) = effect {
                return record.deliveredText == nil
                    && record.outcome == .deliveryFailure(
                        source: .rawTranscriptFallback(.modelUnavailable),
                        reason: .pasteTimedOut,
                        recordingEnd: .released
                    )
            }
            return false
        })
    }

    func testDeviceLossStopsRecognitionWithoutHistory() async {
        let session = DictationSessionActor(clock: OutcomeFakeClock())
        let start = outcomeFixtureStart()
        _ = await session.handle(.press(start))

        let effects = await session.handle(.recordingFailed(start.id, .deviceLost))
        let outcome = await session.snapshot().outcome

        XCTAssertEqual(outcome, .recordingFailure(.deviceLost))
        XCTAssertTrue(effects.contains(.cancelRecognition(start.id)))
        XCTAssertFalse(effects.contains { effect in
            if case .recordHistory = effect { return true }
            return false
        })
    }

    func testFiveMinuteLimitStopsRecordingAndPreservesSafetyStopInFinalOutcome() async {
        let clock = OutcomeFakeClock()
        let session = DictationSessionActor(clock: clock)
        let start = outcomeFixtureStart()

        _ = await session.handle(.press(start))
        clock.advance(by: .seconds(270))
        let warning = await session.handle(.recordingWarningFired(start.id))
        XCTAssertTrue(warning.contains(.presentIndicator(.init(
            dictationID: start.id,
            state: .approachingRecordingLimit(audioActivity: nil)
        ))))

        clock.advance(by: .seconds(30))
        let stop = await session.handle(.recordingLimitFired(start.id))
        XCTAssertTrue(stop.contains { effect in
            if case .stopRecordingAndFinalize = effect { return true }
            return false
        })

        _ = await session.handle(.recognitionCompleted(
            start.id,
            .final(.init(text: "Long dictation"))
        ))
        _ = await session.handle(.cleanupCompleted(
            start.id,
            .cleaned(.init(text: "Long dictation.", metadata: .init(changed: true, editCount: 1)))
        ))
        _ = await session.handle(.targetRevalidated(start.id, .valid))
        _ = await session.handle(.deliveryCompleted(start.id, .inserted(.accessibility)))

        let snapshot = await session.snapshot()
        XCTAssertEqual(snapshot.outcome, .cleanedInsertion(
            method: .accessibility,
            recordingEnd: .fiveMinuteSafetyLimit
        ))
    }
}

private func reachCleanup(
    _ session: DictationSessionActor,
    start: DictationStart,
    rawTranscript: String
) async {
    _ = await session.handle(.press(start))
    _ = await session.handle(.release(start.id))
    _ = await session.handle(.recognitionCompleted(
        start.id,
        .final(.init(text: rawTranscript))
    ))
}

private final class OutcomeFakeClock: MonotonicClock, @unchecked Sendable {
    private var instant = MonotonicInstant.zero
    func now() -> MonotonicInstant { instant }
    func advance(by duration: Duration) { instant = instant.advanced(by: duration) }
}

private func outcomeFixtureStart(
    id: DictationID = .init(),
    secure: Bool = false,
    noTarget: Bool = false,
    selection: TextSelection? = nil
) -> DictationStart {
    if noTarget {
        return DictationStart(
            noTargetID: id,
            occurredAt: Date(timeIntervalSince1970: 1_800_000_000),
            targetContext: .init(
                applicationIdentifier: "com.example.Editor",
                applicationCategory: .textEditor,
                textBeforeCursor: "",
                textAfterCursor: "",
                selectedText: nil
            ),
            personalVocabulary: .init(entries: ["Poptart"])
        )
    }
    if secure {
        return DictationStart(
            secureTargetID: id,
            occurredAt: Date(timeIntervalSince1970: 1_800_000_000),
            applicationIdentifier: "com.example.Editor",
            elementIdentifier: "editor-1"
        )
    }
    return DictationStart(
        id: id,
        occurredAt: Date(timeIntervalSince1970: 1_800_000_000),
        target: .init(
            applicationIdentifier: "com.example.Editor",
            elementIdentifier: "editor-1",
            selection: selection
        ),
        targetContext: .init(
            applicationIdentifier: "com.example.Editor",
            applicationCategory: .textEditor,
            textBeforeCursor: "Before ",
            textAfterCursor: " after",
            selectedText: selection == nil ? nil : "selected"
        ),
        personalVocabulary: .init(entries: ["Poptart"])
    )
}
