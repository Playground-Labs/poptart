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

@Suite("Accessibility capture under secure input")
struct AccessibilitySecureInputCaptureTests {
  @Test("focus that cannot be read is answered as secure while a password field holds input")
  func unreadableFocusUnderSecureInputIsSecure() async {
    let service = await MainActor.run {
      AccessibilityTextService(
        permission: GrantedPermission(),
        secureInput: EnabledSecureInput()
      )
    }

    let capture = await service.captureTarget(for: .init())

    guard case .success(.secure) = capture else {
      Issue.record("expected a secure capture, got \(capture)")
      return
    }
  }

  @Test("focus that cannot be read is a Clipboard Dictation when nothing holds secure input")
  func unreadableFocusWithoutSecureInputIsNoTarget() async {
    let service = await MainActor.run {
      AccessibilityTextService(
        permission: GrantedPermission(),
        secureInput: DisabledSecureInput()
      )
    }

    let capture = await service.captureTarget(for: .init())

    guard case .success(.noTarget) = capture else {
      Issue.record("expected a no-target capture, got \(capture)")
      return
    }
  }
}

private struct GrantedPermission: AccessibilityPermission {
  func isGranted() -> Bool { true }
  func request() -> Bool { true }
}

private struct EnabledSecureInput: SecureInputState {
  func isEnabled() -> Bool { true }
}

private struct DisabledSecureInput: SecureInputState {
  func isEnabled() -> Bool { false }
}
