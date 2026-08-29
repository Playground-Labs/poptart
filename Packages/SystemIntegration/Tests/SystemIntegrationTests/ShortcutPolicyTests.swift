import Carbon.HIToolbox
import CoreGraphics
import Foundation
import Testing

@testable import SystemIntegration

@Suite("Dictation shortcut policy")
struct ShortcutPolicyTests {
  @Test("monitoring does not create an event tap without permission")
  func permissionDenied() {
    let monitor = DictationShortcutMonitor(permission: DeniedKeyboardPermission()) { _ in }
    #expect(monitor.start() == .permissionDenied)
    #expect(monitor.start(requestPermission: true) == .permissionDenied)
  }

  @Test("press, duplicates, unrelated changes, and release form one gesture")
  func oneGesture() {
    var policy = DictationShortcutPolicy()

    #expect(policy.handle(keyCode: 61, flags: [.maskAlternate]) == .pressed)
    #expect(policy.handle(keyCode: 61, flags: [.maskAlternate]) == nil)
    #expect(policy.handle(keyCode: 58, flags: []) == nil)
    #expect(policy.handle(keyCode: 61, flags: []) == .released)
    #expect(policy.handle(keyCode: 61, flags: []) == nil)
  }

  @Test("tap loss releases an active gesture once")
  func tapLoss() {
    var policy = DictationShortcutPolicy()
    #expect(policy.handle(keyCode: 61, flags: [.maskAlternate]) == .pressed)
    #expect(policy.reset() == .released)
    #expect(policy.reset() == nil)
  }

  @Test("Right Option releases even while Left Option remains held")
  func independentOptionSides() {
    var policy = DictationShortcutPolicy()
    #expect(policy.handle(keyCode: 61, isDown: true) == .pressed)
    #expect(policy.handle(keyCode: 61, isDown: false) == .released)
  }

  @Test("the default binding is Right Option")
  func defaultBinding() {
    #expect(DictationShortcutPolicy().binding == .rightOption)
    #expect(ShortcutBinding.rightOption.keyCode == 61)
    #expect(ShortcutBinding.rightOption.displayName == "Right Option")
    #expect(ShortcutBinding.rightOption.identifier == "rightOption")
  }

  @Test("a configured binding forms gestures on its own key code only")
  func configuredBinding() {
    var policy = DictationShortcutPolicy(binding: .leftCommand)

    #expect(policy.binding == .leftCommand)
    #expect(policy.handle(keyCode: 61, isDown: true) == nil)
    #expect(policy.handle(keyCode: 55, isDown: true) == .pressed)
    #expect(policy.handle(keyCode: 61, isDown: false) == nil)
    #expect(policy.handle(keyCode: 55, isDown: false) == .released)
  }

  @Test("a non-Option binding still collapses flags-changed noise")
  func configuredBindingFromFlags() {
    var policy = DictationShortcutPolicy(binding: .rightShift)

    #expect(policy.handle(keyCode: 60, flags: [.maskShift]) == .pressed)
    #expect(policy.handle(keyCode: 60, flags: [.maskShift]) == nil)
    #expect(policy.handle(keyCode: 60, flags: []) == .released)
  }

  @Test("rebinding ignores the previous key code and honors the new one")
  func rebindSwapsKeyCode() {
    var policy = DictationShortcutPolicy()

    #expect(policy.rebind(to: .rightControl) == nil)
    #expect(policy.binding == .rightControl)
    #expect(policy.handle(keyCode: 61, isDown: true) == nil)
    #expect(policy.handle(keyCode: 62, isDown: true) == .pressed)
    #expect(policy.handle(keyCode: 62, isDown: false) == .released)
  }

  @Test("rebinding while the old key is held ends the gesture exactly once")
  func rebindWhileHeldReleases() {
    var policy = DictationShortcutPolicy()

    #expect(policy.handle(keyCode: 61, isDown: true) == .pressed)
    #expect(policy.rebind(to: .leftOption) == .released)
    #expect(policy.reset() == nil)
    #expect(policy.handle(keyCode: 61, isDown: false) == nil)
  }

  @Test("rebinding to the same binding leaves an active gesture untouched")
  func rebindToSameBindingIsInert() {
    var policy = DictationShortcutPolicy()

    #expect(policy.handle(keyCode: 61, isDown: true) == .pressed)
    #expect(policy.rebind(to: .rightOption) == nil)
    #expect(policy.handle(keyCode: 61, isDown: false) == .released)
  }

  @Test("a new binding held at swap time emits no phantom press or release")
  func rebindOntoHeldKeyEmitsNoPhantom() {
    var policy = DictationShortcutPolicy()

    // Both keys are physically down; the swap ends the Right Option gesture.
    #expect(policy.handle(keyCode: 61, isDown: true) == .pressed)
    #expect(policy.rebind(to: .leftOption) == .released)

    // Left Option was already held, so its release is not a gesture end.
    #expect(policy.handle(keyCode: 58, isDown: false) == nil)

    // The next real press on the new binding is a clean gesture.
    #expect(policy.handle(keyCode: 58, isDown: true) == .pressed)
    #expect(policy.handle(keyCode: 58, isDown: false) == .released)
  }

  @Test("the supported bindings are the distinguishable held modifier keys")
  func supportedBindings() {
    let all = ShortcutBinding.allCases

    #expect(all.first == .rightOption)
    #expect(
      all == [
        .rightOption, .leftOption, .rightCommand, .leftCommand,
        .rightControl, .leftControl, .rightShift, .leftShift,
      ]
    )
    #expect(Set(all.map(\.keyCode)).count == all.count)
    #expect(Set(all.map(\.identifier)).count == all.count)
    #expect(Set(all.map(\.displayName)).count == all.count)
    // Caps Lock (57) latches and Fn (63) is claimed by the system, so neither is offered.
    #expect(all.allSatisfy { $0.keyCode != 57 && $0.keyCode != 63 })
  }

  @Test("supported key codes match the macOS virtual key codes")
  func keyCodesMatchVirtualKeyCodes() {
    #expect(ShortcutBinding.rightOption.keyCode == Int64(kVK_RightOption))
    #expect(ShortcutBinding.leftOption.keyCode == Int64(kVK_Option))
    #expect(ShortcutBinding.rightCommand.keyCode == Int64(kVK_RightCommand))
    #expect(ShortcutBinding.leftCommand.keyCode == Int64(kVK_Command))
    #expect(ShortcutBinding.rightControl.keyCode == Int64(kVK_RightControl))
    #expect(ShortcutBinding.leftControl.keyCode == Int64(kVK_Control))
    #expect(ShortcutBinding.rightShift.keyCode == Int64(kVK_RightShift))
    #expect(ShortcutBinding.leftShift.keyCode == Int64(kVK_Shift))
  }

  @Test("a binding is looked up by key code and rejects unsupported keys")
  func bindingLookup() throws {
    #expect(try ShortcutBinding(keyCode: 61) == .rightOption)
    #expect(throws: ShortcutBindingError.unsupportedKeyCode(57)) {
      _ = try ShortcutBinding(keyCode: 57)
    }
    #expect(throws: ShortcutBindingError.unsupportedKeyCode(0)) {
      _ = try ShortcutBinding(keyCode: 0)
    }
  }

  @Test("a binding round-trips through settings storage as a stable identifier")
  func bindingCodableRoundTrip() throws {
    for binding in ShortcutBinding.allCases {
      let data = try JSONEncoder().encode(StoredShortcut(shortcut: binding))
      let json = String(decoding: data, as: UTF8.self)
      #expect(json == #"{"shortcut":"\#(binding.identifier)"}"#)
      #expect(try JSONDecoder().decode(StoredShortcut.self, from: data).shortcut == binding)
    }
  }

  @Test("decoding an unknown binding identifier fails with a typed error")
  func bindingDecodeRejectsUnknownIdentifier() {
    let data = Data(#"{"shortcut":"capsLock"}"#.utf8)
    #expect(throws: ShortcutBindingError.unsupportedIdentifier("capsLock")) {
      _ = try JSONDecoder().decode(StoredShortcut.self, from: data)
    }
  }

  @Test("the monitor exposes its binding and swaps it without emitting a signal")
  func monitorRebind() {
    let signals = SignalRecorder()
    let monitor = DictationShortcutMonitor(permission: DeniedKeyboardPermission()) { signal in
      signals.record(signal)
    }

    #expect(monitor.binding == .rightOption)
    monitor.rebind(to: .leftControl)
    #expect(monitor.binding == .leftControl)
    #expect(signals.recorded.isEmpty)
  }

  @Test("the monitor releases an in-flight gesture when the binding changes")
  func monitorRebindWhileHeld() {
    let signals = SignalRecorder()
    let monitor = DictationShortcutMonitor(permission: DeniedKeyboardPermission()) { signal in
      signals.record(signal)
    }

    #expect(monitor.policy.handle(keyCode: 61, isDown: true) == .pressed)
    monitor.rebind(to: .rightCommand)
    #expect(signals.recorded == [.released])

    monitor.rebind(to: .rightCommand)
    monitor.stop()
    #expect(signals.recorded == [.released])
  }

  @Test("the monitor starts on a configured binding")
  func monitorHonorsInitialBinding() {
    let monitor = DictationShortcutMonitor(
      binding: .leftShift,
      permission: DeniedKeyboardPermission()
    ) { _ in }

    #expect(monitor.binding == .leftShift)
  }
}

private struct StoredShortcut: Codable {
  var shortcut: ShortcutBinding
}

private struct DeniedKeyboardPermission: KeyboardMonitoringPermission {
  func isGranted() -> Bool { false }
  func request() -> Bool { false }
}

private final class SignalRecorder: @unchecked Sendable {
  private let lock = NSLock()
  private var signals: [ShortcutSignal] = []

  var recorded: [ShortcutSignal] {
    lock.lock()
    defer { lock.unlock() }
    return signals
  }

  func record(_ signal: ShortcutSignal) {
    lock.lock()
    signals.append(signal)
    lock.unlock()
  }
}
