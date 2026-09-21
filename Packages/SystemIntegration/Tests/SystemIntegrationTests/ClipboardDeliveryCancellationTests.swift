import DictationCore
import Foundation
import Testing

@testable import SystemIntegration

@Suite("Clipboard delivery after the session gave up")
struct ClipboardDeliveryCancellationTests {
  @Test("clipboard replacement checks refusal at the actual MainActor write")
  func refusalAtWriteWins() async {
    let pasteboard = await MainActor.run { RecordingPasteboard() }
    let coordinator = ClipboardPasteCoordinator(pasteboard: pasteboard)

    let result = await coordinator.replaceClipboard(
      text: "unwanted",
      unlessRefusedBy: { .completionDeadlineExceeded }
    )

    #expect(result == .failed(.completionDeadlineExceeded))
    #expect(await pasteboard.writtenTexts().isEmpty)
  }

  @Test("a cancelled delivery never replaces the clipboard")
  func cancelledDeliveryWritesNothing() async {
    let pasteboard = RecordingPasteboard()
    let service = await makeService(pasteboard: pasteboard, now: 0)
    let id = DictationID()

    await service.cancelDelivery(for: id)
    let result = await service.copyToClipboard(
      .init(id: id, text: "unwanted", deadline: .init(nanoseconds: 1_000)))

    #expect(result == .failed(.cancelled))
    #expect(await pasteboard.writtenTexts().isEmpty)
  }

  @Test("a delivery past its completion deadline never replaces the clipboard")
  func expiredDeliveryWritesNothing() async {
    let pasteboard = RecordingPasteboard()
    let service = await makeService(pasteboard: pasteboard, now: 5_000)

    let result = await service.copyToClipboard(
      .init(id: .init(), text: "too late", deadline: .init(nanoseconds: 1_000)))

    #expect(result == .failed(.completionDeadlineExceeded))
    #expect(await pasteboard.writtenTexts().isEmpty)
  }

  @Test("a live delivery inside its deadline still replaces the clipboard")
  func liveDeliveryWrites() async {
    let pasteboard = RecordingPasteboard()
    let service = await makeService(pasteboard: pasteboard, now: 0)

    let result = await service.copyToClipboard(
      .init(id: .init(), text: "wanted", deadline: .init(nanoseconds: 1_000)))

    #expect(result == .copiedToClipboard)
    #expect(await pasteboard.writtenTexts() == ["wanted"])
  }

  @Test("cancelling one dictation does not silence the next one")
  func cancellingOneDoesNotBlockAnother() async {
    let pasteboard = RecordingPasteboard()
    let service = await makeService(pasteboard: pasteboard, now: 0)

    await service.cancelDelivery(for: .init())
    let result = await service.copyToClipboard(
      .init(id: .init(), text: "wanted", deadline: .init(nanoseconds: 1_000)))

    #expect(result == .copiedToClipboard)
    #expect(await pasteboard.writtenTexts() == ["wanted"])
  }
}

@MainActor
private func makeService(
  pasteboard: RecordingPasteboard,
  now: Int64
) -> AccessibilityTextService {
  AccessibilityTextService(
    clipboard: .init(pasteboard: pasteboard),
    clock: FixedNanosecondClock(now: now)
  )
}

private struct FixedNanosecondClock: IntegrationNanosecondClock {
  let now: Int64
  func nowNanoseconds() -> Int64 { now }
}

@MainActor
private final class RecordingPasteboard: PasteboardClient {
  private var texts: [String] = []

  func snapshot() -> PasteboardSnapshot { .init(items: []) }
  func writeText(
    _ text: String,
    unlessRefusedBy refusal: @MainActor @Sendable () -> DeliveryFailure?
  ) -> ClipboardWriteOutcome {
    if let failure = refusal() { return .suppressed(failure) }
    texts.append(text)
    return .written(changeCount: texts.count)
  }
  func writePromisedText(_ text: String, onRead: @escaping @Sendable () -> Void) -> Int? { nil }
  func changeCount() -> Int { texts.count }
  func restore(_ snapshot: PasteboardSnapshot) -> Bool { true }
  func releasePromisedData() {}
  func writtenTexts() -> [String] { texts }
}
