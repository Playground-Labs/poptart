import Foundation
import Observation
import Persistence

/// One Dictation Record as History shows it: what recognition heard, what Poptart delivered, how
/// the Dictation ended, and how long each stage took.
public struct DictationRecordPresentation: Equatable, Sendable, Identifiable {
    public let id: UUID
    public let createdAt: Date
    public let rawTranscript: String
    public let deliveredText: String
    public let destinationApplication: String
    public let classification: String
    public let outcome: Persistence.DictationOutcome
    public let cleanupChangedText: Bool
    public let timings: String
    /// What the copy action puts on the clipboard: the delivered text, or the Raw Transcript when
    /// nothing was delivered so the words stay recoverable.
    public let copyableText: String
    public let hasRawTranscript: Bool

    public var hasCopyableText: Bool { !copyableText.isEmpty }
}

public enum DictationRecordPresenter {
    /// Names the outcome and fallback in the person's terms. `cleanupChangedText` refines only the
    /// cleaned outcome, where whether Cleanup edited anything is the interesting part.
    public static func classification(
        outcome: Persistence.DictationOutcome,
        cleanupChangedText: Bool
    ) -> String {
        switch outcome {
        case .cleaned:
            return cleanupChangedText ? "Cleanup changed the text" : "Cleanup left the text as heard"
        case .rawTranscript:
            return "Raw Transcript fallback"
        case .oversized:
            return "Too long for Cleanup — deterministic rules only"
        case .recognitionHypothesis:
            return "Recognition fallback — not fully finalized"
        case .copiedToClipboard:
            return "Copied because the target changed"
        case .emptyRecognition:
            return "No usable text"
        case .cancelled:
            return "Cancelled"
        case .safetyStop:
            return "Stopped at the five-minute limit"
        case .recordingFailure:
            return "Recording failed"
        case .deliveryFailure:
            return "Delivery failed"
        }
    }

    public static func timings(_ timings: DictationTimings) -> String {
        "Recognition \(timings.recognitionMilliseconds) ms · "
            + "Cleanup \(timings.cleanupMilliseconds) ms · "
            + "Delivery \(timings.deliveryMilliseconds) ms"
    }

    public static func presentation(for record: Persistence.DictationRecord)
        -> DictationRecordPresentation
    {
        .init(
            id: record.id,
            createdAt: record.createdAt,
            rawTranscript: record.rawTranscript,
            deliveredText: record.deliveredText,
            destinationApplication: record.destinationApplication,
            classification: classification(
                outcome: record.outcome,
                cleanupChangedText: record.cleanupChangedText
            ),
            outcome: record.outcome,
            cleanupChangedText: record.cleanupChangedText,
            timings: timings(record.timings),
            copyableText: record.deliveredText.isEmpty
                ? record.rawTranscript : record.deliveredText,
            hasRawTranscript: !record.rawTranscript.isEmpty
        )
    }
}

/// History is a recovery and trust surface: it reads Dictation Records, copies text back out, and
/// deletes them. It never writes a Dictation Record and never reports anything anywhere.
@MainActor
@Observable
public final class HistoryListModel {
    public private(set) var records: [DictationRecordPresentation] = []
    public private(set) var message: String?

    public let retentionDescription =
        "Dictation Records stay on this Mac, encrypted, and expire after 30 days."

    private let store: any DictationRecordStoring
    private let clipboard: any TextCopying

    public init(store: any DictationRecordStoring, clipboard: any TextCopying) {
        self.store = store
        self.clipboard = clipboard
    }

    public func reload() async {
        do {
            records = try await store.records()
                .sorted { $0.createdAt > $1.createdAt }
                .map(DictationRecordPresenter.presentation(for:))
            message = nil
        } catch {
            records = []
            message = "History cannot be read on this Mac. Clear History removes what is unreadable."
        }
    }

    public func copyDeliveredText(_ id: UUID) async {
        guard let record = records.first(where: { $0.id == id }), record.hasCopyableText else {
            return
        }
        message = await clipboard.copy(record.copyableText)
            ? "Copied to the clipboard." : "The clipboard refused the copy."
    }

    public func copyRawTranscript(_ id: UUID) async {
        guard let record = records.first(where: { $0.id == id }), record.hasRawTranscript else {
            return
        }
        message = await clipboard.copy(record.rawTranscript)
            ? "Copied the Raw Transcript to the clipboard." : "The clipboard refused the copy."
    }

    public func delete(_ id: UUID) async {
        do {
            try await store.delete(id)
            records.removeAll { $0.id == id }
            message = nil
        } catch {
            message = "That Dictation Record could not be deleted."
        }
    }

    public func clearHistory() async {
        do {
            try await store.clearHistory()
            records = []
            message = "History is empty."
        } catch {
            message = "History could not be cleared."
        }
    }
}
