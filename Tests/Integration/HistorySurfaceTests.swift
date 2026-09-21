import Foundation
import ModelRuntime
import Persistence
import Testing

@testable import PoptartApplication

@Suite("History surface")
@MainActor
struct HistorySurfaceTests {
    @Test("Dictation Records are listed newest first")
    func recordsAreChronological() async {
        let oldest = stubRecord(createdAt: Date(timeIntervalSince1970: 100))
        let newest = stubRecord(createdAt: Date(timeIntervalSince1970: 900))
        let middle = stubRecord(createdAt: Date(timeIntervalSince1970: 500))
        let model = HistoryListModel(
            store: StubRecordStore(stored: [oldest, newest, middle]),
            clipboard: StubClipboard()
        )

        await model.reload()

        #expect(model.records.map(\.id) == [newest.id, middle.id, oldest.id])
    }

    @Test("every Dictation Record shows the Raw Transcript, the delivered text, and its timings")
    func recordsShowBothTextsAndTimings() async throws {
        let record = stubRecord(
            rawTranscript: "um hello world",
            deliveredText: "Hello, world.",
            timings: .init(
                recognitionMilliseconds: 210,
                cleanupMilliseconds: 640,
                deliveryMilliseconds: 15
            )
        )
        let model = HistoryListModel(
            store: StubRecordStore(stored: [record]), clipboard: StubClipboard())

        await model.reload()
        let presented = try #require(model.records.first)

        #expect(presented.rawTranscript == "um hello world")
        #expect(presented.deliveredText == "Hello, world.")
        #expect(presented.hasRawTranscript)
        #expect(presented.timings == "Recognition 210 ms · Cleanup 640 ms · Delivery 15 ms")
        #expect(presented.destinationApplication == "com.example.Editor")
    }

    @Test(
        "every outcome is classified in the person's terms",
        arguments: Persistence.DictationOutcome.allCases
    )
    func everyOutcomeIsClassified(outcome: Persistence.DictationOutcome) {
        let expected: String =
            switch outcome {
            case .cleaned: "Cleanup changed the text"
            case .rawTranscript: "Raw Transcript fallback"
            case .oversized: "Too long for Cleanup — deterministic rules only"
            case .recognitionHypothesis: "Recognition fallback — not fully finalized"
            case .copiedTargetChanged: "Copied because the target changed"
            case .copiedNoTarget: "Copied because no text field was focused"
            case .emptyRecognition: "No usable text"
            case .cancelled: "Cancelled"
            case .safetyStop: "Stopped at the five-minute limit"
            case .recordingFailure: "Recording failed"
            case .deliveryFailure: "Delivery failed"
            }

        #expect(
            DictationRecordPresenter.classification(outcome: outcome, cleanupChangedText: true)
                == expected)
    }

    @Test(
        "a Raw Transcript fallback says why Cleanup stepped aside",
        arguments: [
            (Persistence.RawTranscriptFallbackReason.cleanupTimedOut, "Cleanup timed out"),
            (.cleanupFailed, "Cleanup failed"),
            (.unsafeEditPlan, "Cleanup's edits were unsafe"),
            (.modelUnavailable, "The Cleanup model was unavailable"),
        ]
    )
    func fallbackReasonIsNamed(
        reason: Persistence.RawTranscriptFallbackReason,
        named: String
    ) {
        #expect(
            DictationRecordPresenter.classification(
                outcome: .rawTranscript,
                cleanupChangedText: false,
                fallbackReason: reason
            ) == "Raw Transcript fallback — \(named)")
    }

    @Test("a copy says why Cleanup stepped aside as well as why it was a copy")
    func fallbackReasonIsNamedOnACopy() {
        #expect(
            DictationRecordPresenter.classification(
                outcome: .copiedNoTarget,
                cleanupChangedText: false,
                fallbackReason: .cleanupTimedOut
            ) == "Copied because no text field was focused — Cleanup timed out")
    }

    @Test("a cleaned Dictation says so when Cleanup left the words alone")
    func unchangedCleanupIsDistinguished() {
        #expect(
            DictationRecordPresenter.classification(outcome: .cleaned, cleanupChangedText: false)
                == "Cleanup left the text as heard")
    }

    @Test("copying puts the delivered text on the clipboard")
    func copyingDeliveredText() async {
        let record = stubRecord()
        let clipboard = StubClipboard()
        let model = HistoryListModel(
            store: StubRecordStore(stored: [record]), clipboard: clipboard)
        await model.reload()

        await model.copyDeliveredText(record.id)

        #expect(await clipboard.copied == ["Hello, world."])
        #expect(model.message == "Copied to the clipboard.")
    }

    @Test("the Raw Transcript stays recoverable on its own")
    func copyingRawTranscript() async {
        let record = stubRecord(rawTranscript: "um hello world")
        let clipboard = StubClipboard()
        let model = HistoryListModel(
            store: StubRecordStore(stored: [record]), clipboard: clipboard)
        await model.reload()

        await model.copyRawTranscript(record.id)

        #expect(await clipboard.copied == ["um hello world"])
        #expect(model.message == "Copied the Raw Transcript to the clipboard.")
    }

    @Test("a Dictation that delivered nothing still copies the words recognition heard")
    func copyFallsBackToTheRawTranscript() async {
        let record = stubRecord(
            rawTranscript: "keep this",
            deliveredText: "",
            outcome: .deliveryFailure
        )
        let clipboard = StubClipboard()
        let model = HistoryListModel(
            store: StubRecordStore(stored: [record]), clipboard: clipboard)
        await model.reload()

        await model.copyDeliveredText(record.id)

        #expect(await clipboard.copied == ["keep this"])
    }

    @Test("a Dictation with no text at all offers nothing to copy")
    func recordWithoutTextCannotBeCopied() async {
        let record = stubRecord(rawTranscript: "", deliveredText: "", outcome: .emptyRecognition)
        let clipboard = StubClipboard()
        let model = HistoryListModel(
            store: StubRecordStore(stored: [record]), clipboard: clipboard)
        await model.reload()

        await model.copyDeliveredText(record.id)
        await model.copyRawTranscript(record.id)

        #expect(await clipboard.copied.isEmpty)
        #expect(model.records.first?.hasCopyableText == false)
    }

    @Test("a refused clipboard is reported instead of pretending the copy worked")
    func refusedClipboardIsReported() async {
        let record = stubRecord()
        let clipboard = StubClipboard(accepts: false)
        let model = HistoryListModel(
            store: StubRecordStore(stored: [record]), clipboard: clipboard)
        await model.reload()

        await model.copyDeliveredText(record.id)

        #expect(model.message == "The clipboard refused the copy.")
    }

    @Test("deleting one Dictation Record leaves the rest")
    func deletingOneRecord() async {
        let kept = stubRecord(createdAt: Date(timeIntervalSince1970: 900))
        let removed = stubRecord(createdAt: Date(timeIntervalSince1970: 100))
        let store = StubRecordStore(stored: [kept, removed])
        let model = HistoryListModel(store: store, clipboard: StubClipboard())
        await model.reload()

        await model.delete(removed.id)

        #expect(model.records.map(\.id) == [kept.id])
        #expect(await store.stored.map(\.id) == [kept.id])
    }

    @Test("Clear History empties the surface and the store")
    func clearHistoryEmptiesEverything() async {
        let store = StubRecordStore(stored: [stubRecord(), stubRecord()])
        let model = HistoryListModel(store: store, clipboard: StubClipboard())
        await model.reload()

        await model.clearHistory()

        #expect(model.records.isEmpty)
        #expect(await store.stored.isEmpty)
        #expect(model.message == "History is empty.")
    }

    @Test("history that cannot be decrypted says so instead of looking empty")
    func unreadableHistoryIsReported() async {
        let model = HistoryListModel(
            store: StubRecordStore(readFailure: PersistenceError.unreadableProtectedData),
            clipboard: StubClipboard()
        )

        await model.reload()

        #expect(model.records.isEmpty)
        #expect(
            model.message
                == "History cannot be read on this Mac. Clear History removes what is unreadable.")
    }

    @Test("a Dictation Record that will not delete says so")
    func failedDeleteIsReported() async {
        let record = stubRecord()
        let model = HistoryListModel(
            store: StubRecordStore(stored: [record], mutationFailure: StubError("locked")),
            clipboard: StubClipboard()
        )
        await model.reload()

        await model.delete(record.id)

        #expect(model.records.count == 1)
        #expect(model.message == "That Dictation Record could not be deleted.")
    }
}

@Suite("Application launch")
@MainActor
struct ApplicationLaunchModelTests {
    @Test("no installed pack means there is nothing to start")
    func missingPackStopsStartup() async {
        let model = ApplicationLaunchModel(modelPacks: StubModelPackProvider()) { _ in
            Issue.record("the runtime must not start without a pack")
        }

        await model.start()

        #expect(model.status == .modelPackRequired)
    }

    @Test("an unreadable pack registry points at Repair Model Pack")
    func unreadableRegistryPointsAtRepair() async {
        let model = ApplicationLaunchModel(
            modelPacks: StubModelPackProvider(failure: ModelPackError.invalidActiveState)
        ) { _ in Issue.record("the runtime must not start from an unreadable registry") }

        await model.start()

        #expect(
            model.status
                == .failed("The verified Model Pack registry is unreadable. Use Repair Model Pack."))
    }

    @Test(
        "a missing permission is named rather than reported as a failure",
        arguments: [
            (RuntimeAssemblyError.microphonePermissionRequired, RequiredPermission.microphone),
            (.accessibilityPermissionRequired, .accessibility),
            (.shortcutPermissionRequired, .keyboardMonitoring),
        ]
    )
    func permissionErrorsAreNamed(
        error: RuntimeAssemblyError,
        permission: RequiredPermission
    ) async {
        let model = ApplicationLaunchModel(
            modelPacks: StubModelPackProvider(pack: .stub())
        ) { _ in throw error }

        await model.start()

        #expect(model.status == .permissionRequired(permission))
        #expect(model.status.message == "Allow \(permission.displayName).")
    }

    @Test("a runtime that starts is ready and is not started twice")
    func startingOnceIsEnough() async {
        let starts = Box(0)
        let model = ApplicationLaunchModel(modelPacks: StubModelPackProvider(pack: .stub())) { _ in
            starts.mutate { $0 += 1 }
        }

        await model.start()
        await model.start()

        #expect(model.status == .ready)
        #expect(starts.value == 1)
        #expect(model.activePack?.cleanupTokenCeiling == 768)
    }

    @Test("pack activation waits for initial startup and reloads the newly installed pack")
    func restartAfterPackInstallationWaitsForStartup() async {
        let provider = StubModelPackProvider(pack: .stub(version: "1.0.0"))
        let started = AsyncStream<Void>.makeStream()
        let resume = AsyncStream<Void>.makeStream()
        let versions = Box<[String]>([])
        let model = ApplicationLaunchModel(modelPacks: provider) { pack in
            versions.mutate { $0.append(pack.version) }
            if versions.value.count == 1 {
                started.continuation.yield(())
                for await _ in resume.stream { break }
            }
        }
        let first = Task { await model.start() }
        for await _ in started.stream { break }
        await provider.install(.stub(version: "1.1.0"))
        let restarting = Task { await model.restart() }
        resume.continuation.yield(())
        await first.value
        await restarting.value
        #expect(versions.value == ["1.0.0", "1.1.0"])
        #expect(model.status == .ready)
        #expect(model.activePack?.version == "1.1.0")
        started.continuation.finish()
        resume.continuation.finish()
    }

    @Test("restarting tries again after a permission is granted")
    func restartTriesAgain() async {
        let granted = Box(false)
        let model = ApplicationLaunchModel(modelPacks: StubModelPackProvider(pack: .stub())) { _ in
            guard granted.value else { throw RuntimeAssemblyError.accessibilityPermissionRequired }
        }

        await model.start()
        #expect(model.status == .permissionRequired(.accessibility))

        granted.value = true
        await model.restart()

        #expect(model.status == .ready)
    }

    @Test("an unexplained startup failure still points somewhere useful")
    func unexpectedFailureIsExplained() async {
        let model = ApplicationLaunchModel(modelPacks: StubModelPackProvider(pack: .stub())) { _ in
            throw StubError("model load")
        }

        await model.start()

        #expect(
            model.status
                == .failed("The local models did not start. Use Repair Model Pack and try again."))
    }
}
