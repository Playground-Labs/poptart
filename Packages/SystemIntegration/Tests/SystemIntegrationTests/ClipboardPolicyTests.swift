import Testing

@testable import SystemIntegration

@Suite("Clipboard paste receipt")
struct ClipboardPolicyTests {
  @Test("restoration waits for quiet after the last genuine read")
  func quietPeriod() {
    let receipt = ClipboardPasteReceipt(
      changeCount: 7,
      pasteDispatchedAtNanoseconds: 1_000,
      lastReadAtNanoseconds: 1_020
    )
    let policy = ClipboardRestorationPolicy(
      quietPeriodNanoseconds: 75,
      pollIntervalNanoseconds: 10
    )

    #expect(
      policy.decision(receipt: receipt, nowNanoseconds: 1_094, currentChangeCount: 7) == .wait)
    #expect(
      policy.decision(receipt: receipt, nowNanoseconds: 1_095, currentChangeCount: 7) == .restore)
  }

  @Test("a receipt without a genuine read cannot restore as successful")
  func noRead() {
    let receipt = ClipboardPasteReceipt(
      changeCount: 7,
      pasteDispatchedAtNanoseconds: 1_000,
      lastReadAtNanoseconds: nil
    )
    #expect(
      ClipboardRestorationPolicy().decision(
        receipt: receipt,
        nowNanoseconds: 2_000,
        currentChangeCount: 7
      ) == .wait)
  }

  @Test("foreign clipboard ownership prevents restoration")
  func ownershipChanged() {
    let receipt = ClipboardPasteReceipt(
      changeCount: 7,
      pasteDispatchedAtNanoseconds: 1_000,
      lastReadAtNanoseconds: 1_020
    )

    #expect(
      ClipboardRestorationPolicy().decision(
        receipt: receipt,
        nowNanoseconds: 1_095,
        currentChangeCount: 8
      ) == .ownershipChanged)
  }
}
