import AppKit
import CoreGraphics
import DictationCore
import Foundation

public struct PasteboardItemSnapshot: Equatable, Sendable {
  public let valuesByType: [String: Data]

  public init(valuesByType: [String: Data]) {
    self.valuesByType = valuesByType
  }
}

public struct PasteboardSnapshot: Equatable, Sendable {
  public let items: [PasteboardItemSnapshot]

  public init(items: [PasteboardItemSnapshot]) {
    self.items = items
  }
}

public protocol PasteboardClient: Sendable {
  func snapshot() async -> PasteboardSnapshot
  func writeText(_ text: String) async -> Int?
  func writePromisedText(_ text: String, onRead: @escaping @Sendable () -> Void) async -> Int?
  func changeCount() async -> Int
  func restore(_ snapshot: PasteboardSnapshot) async -> Bool
  func releasePromisedData() async
}

public struct SystemPasteboardClient: PasteboardClient {
  public init() {}

  public func snapshot() async -> PasteboardSnapshot {
    await MainActor.run {
      let items = NSPasteboard.general.pasteboardItems ?? []
      return PasteboardSnapshot(
        items: items.map { item in
          var values: [String: Data] = [:]
          for type in item.types {
            if let data = item.data(forType: type) {
              values[type.rawValue] = data
            }
          }
          return PasteboardItemSnapshot(valuesByType: values)
        })
    }
  }

  public func writeText(_ text: String) async -> Int? {
    await MainActor.run {
      PromisedPasteboardStore.shared.releaseProvider()
      let pasteboard = NSPasteboard.general
      pasteboard.clearContents()
      guard pasteboard.setString(text, forType: .string) else { return nil }
      return pasteboard.changeCount
    }
  }

  public func writePromisedText(
    _ text: String,
    onRead: @escaping @Sendable () -> Void
  ) async -> Int? {
    await MainActor.run {
      PromisedPasteboardStore.shared.write(text: text, onRead: onRead)
    }
  }

  public func changeCount() async -> Int {
    await MainActor.run { NSPasteboard.general.changeCount }
  }

  public func restore(_ snapshot: PasteboardSnapshot) async -> Bool {
    await MainActor.run {
      PromisedPasteboardStore.shared.releaseProvider()
      let pasteboard = NSPasteboard.general
      pasteboard.clearContents()
      guard !snapshot.items.isEmpty else { return true }
      let items = snapshot.items.map { snapshotItem in
        let item = NSPasteboardItem()
        for (rawType, data) in snapshotItem.valuesByType {
          item.setData(data, forType: .init(rawValue: rawType))
        }
        return item
      }
      return pasteboard.writeObjects(items)
    }
  }

  public func releasePromisedData() async {
    await MainActor.run { PromisedPasteboardStore.shared.releaseProvider() }
  }
}

public protocol PasteCommandSynthesizer: Sendable {
  func paste() async -> Bool
}

public struct SystemPasteCommandSynthesizer: PasteCommandSynthesizer {
  public init() {}

  public func paste() async -> Bool {
    guard let source = CGEventSource(stateID: .combinedSessionState),
      let down = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: true),
      let up = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: false)
    else { return false }
    down.flags = .maskCommand
    up.flags = .maskCommand
    down.post(tap: .cghidEventTap)
    up.post(tap: .cghidEventTap)
    return true
  }
}

public protocol IntegrationNanosecondClock: Sendable {
  func nowNanoseconds() -> Int64
}

public struct SystemIntegrationClock: IntegrationNanosecondClock {
  public init() {}

  public func nowNanoseconds() -> Int64 {
    Int64(clamping: DispatchTime.now().uptimeNanoseconds)
  }
}

public protocol IntegrationSleeper: Sendable {
  func sleep(nanoseconds: UInt64) async
}

public struct SystemIntegrationSleeper: IntegrationSleeper {
  public init() {}

  public func sleep(nanoseconds: UInt64) async {
    try? await Task.sleep(nanoseconds: nanoseconds)
  }
}

/// Owns a single pasteboard receipt from write through conditional restoration.
public struct ClipboardPasteCoordinator: Sendable {
  private let pasteboard: any PasteboardClient
  private let synthesizer: any PasteCommandSynthesizer
  private let clock: any IntegrationNanosecondClock
  private let sleeper: any IntegrationSleeper
  private let policy: ClipboardRestorationPolicy

  public init(
    pasteboard: any PasteboardClient = SystemPasteboardClient(),
    synthesizer: any PasteCommandSynthesizer = SystemPasteCommandSynthesizer(),
    clock: any IntegrationNanosecondClock = SystemIntegrationClock(),
    sleeper: any IntegrationSleeper = SystemIntegrationSleeper(),
    policy: ClipboardRestorationPolicy = .init()
  ) {
    self.pasteboard = pasteboard
    self.synthesizer = synthesizer
    self.clock = clock
    self.sleeper = sleeper
    self.policy = policy
  }

  public func pastePreservingClipboard(text: String, deadline: MonotonicInstant) async
    -> DeliveryResult
  {
    let now = clock.nowNanoseconds()
    guard deadline.nanoseconds - now >= policy.quietPeriodNanoseconds else {
      return .failed(.pasteTimedOut)
    }

    let previous = await pasteboard.snapshot()
    let tracker = ClipboardReadTracker()
    let promisedWrite = await pasteboard.writePromisedText(
      text,
      onRead: {
        tracker.recordProviderRead(at: clock.nowNanoseconds())
      })
    guard let receiptCount = promisedWrite else {
      return .failed(.clipboardWriteFailed)
    }
    guard await synthesizer.paste() else {
      if await pasteboard.changeCount() == receiptCount {
        _ = await pasteboard.restore(previous)
      } else {
        await pasteboard.releasePromisedData()
      }
      return .failed(.accessibilityAndPasteFailed)
    }
    tracker.markPasteDispatched(at: clock.nowNanoseconds())

    while true {
      let now = clock.nowNanoseconds()
      let currentChangeCount = await pasteboard.changeCount()
      guard let receipt = tracker.receipt(changeCount: receiptCount) else {
        return .failed(.pasteTimedOut)
      }
      switch policy.decision(
        receipt: receipt,
        nowNanoseconds: now,
        currentChangeCount: currentChangeCount
      ) {
      case .restore:
        return await pasteboard.restore(previous)
          ? .inserted(.clipboardPaste)
          : .failed(.clipboardWriteFailed)
      case .ownershipChanged:
        await pasteboard.releasePromisedData()
        return .failed(.clipboardOwnershipChanged)
      case .wait:
        guard now < deadline.nanoseconds else {
          if await pasteboard.changeCount() == receiptCount {
            _ = await pasteboard.restore(previous)
          }
          return .failed(.pasteTimedOut)
        }
        let quietRemaining = receipt.lastReadAtNanoseconds.map {
          max(1, $0 + policy.quietPeriodNanoseconds - now)
        }
        let deadlineRemaining = deadline.nanoseconds - now
        let wait = min(
          policy.pollIntervalNanoseconds,
          quietRemaining ?? policy.pollIntervalNanoseconds,
          deadlineRemaining
        )
        await sleeper.sleep(nanoseconds: UInt64(max(1, wait)))
      }
    }
  }

  public func replaceClipboard(text: String) async -> DeliveryResult {
    await pasteboard.writeText(text) == nil
      ? .failed(.clipboardWriteFailed)
      : .copiedToClipboard
  }
}

@MainActor
private final class PromisedPasteboardStore {
  static let shared = PromisedPasteboardStore()

  private var provider: PromisedStringDataProvider?

  func write(text: String, onRead: @escaping @Sendable () -> Void) -> Int? {
    let pasteboard = NSPasteboard.general
    releaseProvider()
    pasteboard.clearContents()
    let item = NSPasteboardItem()
    let provider = PromisedStringDataProvider(text: text, onRead: onRead)
    item.setDataProvider(provider, forTypes: [.string])
    guard pasteboard.writeObjects([item]) else { return nil }
    self.provider = provider
    return pasteboard.changeCount
  }

  func releaseProvider() {
    provider = nil
  }
}

@MainActor
private final class PromisedStringDataProvider: NSObject, NSPasteboardItemDataProvider {
  private let text: String
  private let onRead: @Sendable () -> Void

  init(text: String, onRead: @escaping @Sendable () -> Void) {
    self.text = text
    self.onRead = onRead
  }

  func pasteboard(
    _ pasteboard: NSPasteboard?,
    item: NSPasteboardItem,
    provideDataForType type: NSPasteboard.PasteboardType
  ) {
    onRead()
    item.setString(text, forType: type)
  }
}
