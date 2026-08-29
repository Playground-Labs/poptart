import CoreGraphics

public enum ShortcutSignal: Equatable, Sendable {
  case pressed
  case released
}

/// Collapses flags-changed noise into one press and one release per gesture on
/// the bound Dictation shortcut key.
public struct DictationShortcutPolicy: Sendable {
  /// The key the policy currently listens for. Swap it with ``rebind(to:)``.
  public private(set) var binding: ShortcutBinding

  private var isPressed = false

  public init(binding: ShortcutBinding = .rightOption) {
    self.binding = binding
  }

  public mutating func handle(keyCode: Int64, flags: CGEventFlags) -> ShortcutSignal? {
    handle(keyCode: keyCode, isDown: flags.contains(binding.eventFlag))
  }

  public mutating func handle(keyCode: Int64, isDown: Bool) -> ShortcutSignal? {
    guard keyCode == binding.keyCode else { return nil }
    guard isDown != isPressed else { return nil }
    isPressed = isDown
    return isDown ? .pressed : .released
  }

  /// Points the shortcut at another key, taking effect on the next press.
  ///
  /// A gesture in flight belongs to the old key, whose release will no longer be
  /// recognized, so the swap ends it here rather than stranding it. The new key
  /// starts unpressed: if it happens to be held at swap time, its release is
  /// absorbed and only the following press begins a gesture.
  public mutating func rebind(to binding: ShortcutBinding) -> ShortcutSignal? {
    guard binding != self.binding else { return nil }
    self.binding = binding
    return reset()
  }

  /// Ends an active gesture when monitoring is stopped or macOS disables the tap.
  public mutating func reset() -> ShortcutSignal? {
    guard isPressed else { return nil }
    isPressed = false
    return .released
  }
}
