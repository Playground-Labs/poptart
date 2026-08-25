import CoreGraphics

public enum ShortcutSignal: Equatable, Sendable {
  case pressed
  case released
}

/// Collapses flags-changed noise into one press and one release per Right Option gesture.
public struct RightOptionShortcutPolicy: Sendable {
  public static let rightOptionKeyCode: Int64 = 61

  private var isPressed = false

  public init() {}

  public mutating func handle(keyCode: Int64, flags: CGEventFlags) -> ShortcutSignal? {
    handle(keyCode: keyCode, isDown: flags.contains(.maskAlternate))
  }

  public mutating func handle(keyCode: Int64, isDown: Bool) -> ShortcutSignal? {
    guard keyCode == Self.rightOptionKeyCode else { return nil }
    guard isDown != isPressed else { return nil }
    isPressed = isDown
    return isDown ? .pressed : .released
  }

  /// Ends an active gesture when monitoring is stopped or macOS disables the tap.
  public mutating func reset() -> ShortcutSignal? {
    guard isPressed else { return nil }
    isPressed = false
    return .released
  }
}
