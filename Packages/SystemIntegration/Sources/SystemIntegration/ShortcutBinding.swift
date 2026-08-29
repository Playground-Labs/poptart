import CoreGraphics

public enum ShortcutBindingError: Error, Equatable, Sendable {
  case unsupportedKeyCode(Int64)
  case unsupportedIdentifier(String)
}

/// The single held modifier key that starts and ends a Dictation.
///
/// Only modifier keys that the flags-changed event stream reports as a distinct
/// virtual key code are offered, so left and right sides stay independent. Caps
/// Lock latches instead of reporting a hold, and Fn is claimed by the system
/// before an event tap sees it, so neither can back a press-and-hold gesture.
public struct ShortcutBinding: Hashable, Sendable, CaseIterable {
  /// The macOS virtual key code (`kVK_*`) carried by the key's flags-changed events.
  public var keyCode: Int64 { key.keyCode }

  /// The stable token used to persist the binding; safe to write to settings.
  public var identifier: String { key.rawValue }

  /// The user-facing name for onboarding and settings, in Apple's key spelling.
  public var displayName: String {
    switch key {
    case .rightOption: "Right Option"
    case .leftOption: "Left Option"
    case .rightCommand: "Right Command"
    case .leftCommand: "Left Command"
    case .rightControl: "Right Control"
    case .leftControl: "Left Control"
    case .rightShift: "Right Shift"
    case .leftShift: "Left Shift"
    }
  }

  /// The event flag raised while the key is held. The flag is side-agnostic, so
  /// it cannot tell the two Option keys apart; prefer the key code wherever the
  /// side matters.
  var eventFlag: CGEventFlags {
    switch key {
    case .rightOption, .leftOption: .maskAlternate
    case .rightCommand, .leftCommand: .maskCommand
    case .rightControl, .leftControl: .maskControl
    case .rightShift, .leftShift: .maskShift
    }
  }

  private let key: Key

  private init(_ key: Key) {
    self.key = key
  }

  /// Resolves a supported binding from a virtual key code.
  public init(keyCode: Int64) throws(ShortcutBindingError) {
    guard let key = Key.allCases.first(where: { $0.keyCode == keyCode }) else {
      throw .unsupportedKeyCode(keyCode)
    }
    self.init(key)
  }

  /// Resolves a supported binding from a persisted identifier.
  public init(identifier: String) throws(ShortcutBindingError) {
    guard let key = Key(rawValue: identifier) else {
      throw .unsupportedIdentifier(identifier)
    }
    self.init(key)
  }

  public static let rightOption = ShortcutBinding(.rightOption)
  public static let leftOption = ShortcutBinding(.leftOption)
  public static let rightCommand = ShortcutBinding(.rightCommand)
  public static let leftCommand = ShortcutBinding(.leftCommand)
  public static let rightControl = ShortcutBinding(.rightControl)
  public static let leftControl = ShortcutBinding(.leftControl)
  public static let rightShift = ShortcutBinding(.rightShift)
  public static let leftShift = ShortcutBinding(.leftShift)

  /// Every binding a person may choose, in the order settings should list them.
  public static let allCases: [ShortcutBinding] = Key.allCases.map { ShortcutBinding($0) }

  private enum Key: String, CaseIterable, Sendable {
    case rightOption
    case leftOption
    case rightCommand
    case leftCommand
    case rightControl
    case leftControl
    case rightShift
    case leftShift

    var keyCode: Int64 {
      switch self {
      case .rightOption: 61  // kVK_RightOption
      case .leftOption: 58  // kVK_Option
      case .rightCommand: 54  // kVK_RightCommand
      case .leftCommand: 55  // kVK_Command
      case .rightControl: 62  // kVK_RightControl
      case .leftControl: 59  // kVK_Control
      case .rightShift: 60  // kVK_RightShift
      case .leftShift: 56  // kVK_Shift
      }
    }
  }
}

extension ShortcutBinding: Codable {
  public init(from decoder: any Decoder) throws {
    let identifier = try decoder.singleValueContainer().decode(String.self)
    try self.init(identifier: identifier)
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.singleValueContainer()
    try container.encode(identifier)
  }
}
