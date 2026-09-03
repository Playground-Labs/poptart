import DictationCore
import Foundation
import Testing

@testable import SystemIntegration

@Suite("Accessibility text service concurrency")
struct AccessibilityTextServiceConcurrencyTests {
  @Test("delivery enters the main thread before touching Accessibility")
  func deliveryRunsOnMainThread() async {
    let permission = ThreadRecordingPermission()
    let service = await MainActor.run { AccessibilityTextService(permission: permission) }
    let request = DeliveryRequest(
      id: .init(),
      target: .init(
        applicationIdentifier: "labs.playground.Poptart",
        elementIdentifier: "missing",
        selection: nil
      ),
      text: "dictated",
      deadline: .zero
    )

    _ = await Task.detached { await service.deliver(request) }.value

    #expect(permission.wasCheckedOnMainThread == true)
  }
}

private final class ThreadRecordingPermission: AccessibilityPermission, @unchecked Sendable {
  private let lock = NSLock()
  private var checkedOnMainThread: Bool?

  var wasCheckedOnMainThread: Bool? {
    lock.withLock { checkedOnMainThread }
  }

  func isGranted() -> Bool {
    lock.withLock { checkedOnMainThread = Thread.isMainThread }
    return false
  }

  func request() -> Bool { false }
}
