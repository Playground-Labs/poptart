import CoreGraphics
import Testing

@testable import SystemIntegration

@Suite("Right Option shortcut policy")
struct ShortcutPolicyTests {
  @Test("monitoring does not create an event tap without permission")
  func permissionDenied() {
    let monitor = RightOptionShortcutMonitor(permission: DeniedKeyboardPermission()) { _ in }
    #expect(monitor.start() == .permissionDenied)
    #expect(monitor.start(requestPermission: true) == .permissionDenied)
  }

  @Test("press, duplicates, unrelated changes, and release form one gesture")
  func oneGesture() {
    var policy = RightOptionShortcutPolicy()

    #expect(policy.handle(keyCode: 61, flags: [.maskAlternate]) == .pressed)
    #expect(policy.handle(keyCode: 61, flags: [.maskAlternate]) == nil)
    #expect(policy.handle(keyCode: 58, flags: []) == nil)
    #expect(policy.handle(keyCode: 61, flags: []) == .released)
    #expect(policy.handle(keyCode: 61, flags: []) == nil)
  }

  @Test("tap loss releases an active gesture once")
  func tapLoss() {
    var policy = RightOptionShortcutPolicy()
    #expect(policy.handle(keyCode: 61, flags: [.maskAlternate]) == .pressed)
    #expect(policy.reset() == .released)
    #expect(policy.reset() == nil)
  }

  @Test("Right Option releases even while Left Option remains held")
  func independentOptionSides() {
    var policy = RightOptionShortcutPolicy()
    #expect(policy.handle(keyCode: 61, isDown: true) == .pressed)
    #expect(policy.handle(keyCode: 61, isDown: false) == .released)
  }
}

private struct DeniedKeyboardPermission: KeyboardMonitoringPermission {
  func isGranted() -> Bool { false }
  func request() -> Bool { false }
}
