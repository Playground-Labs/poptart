import DictationCore
import Foundation

public struct TargetContextRanges: Equatable, Sendable {
  public let before: NSRange
  public let selected: NSRange
  public let after: NSRange
  public let capturedSelection: TextSelection

  public init(before: NSRange, selected: NSRange, after: NSRange, capturedSelection: TextSelection)
  {
    self.before = before
    self.selected = selected
    self.after = after
    self.capturedSelection = capturedSelection
  }
}

/// Computes only the parameterized ranges the Accessibility adapter may read.
public struct TargetContextBounds: Equatable, Sendable {
  public let maximumUTF16CodeUnitsPerSide: Int

  public init(maximumUTF16CodeUnitsPerSide: Int = 512) {
    precondition(maximumUTF16CodeUnitsPerSide > 0)
    self.maximumUTF16CodeUnitsPerSide = maximumUTF16CodeUnitsPerSide
  }

  public func ranges(characterCount: Int, selection: TextSelection) -> TargetContextRanges {
    let count = max(0, characterCount)
    let location = min(selection.location, count)
    let selectionLength = min(selection.length, count - location)
    let beforeLength = min(maximumUTF16CodeUnitsPerSide, location)
    let selectedLength = min(maximumUTF16CodeUnitsPerSide, selectionLength)
    let afterStart = location + selectionLength
    let afterLength = min(maximumUTF16CodeUnitsPerSide, count - afterStart)

    return .init(
      before: NSRange(location: location - beforeLength, length: beforeLength),
      selected: NSRange(location: location, length: selectedLength),
      after: NSRange(location: afterStart, length: afterLength),
      capturedSelection: selection
    )
  }
}

public struct FocusedTargetFingerprint: Equatable, Sendable {
  public let applicationIdentifier: String
  public let elementToken: String
  public let selection: TextSelection?

  public init(applicationIdentifier: String, elementToken: String, selection: TextSelection?) {
    self.applicationIdentifier = applicationIdentifier
    self.elementToken = elementToken
    self.selection = selection
  }
}

public enum TargetRevalidationPolicy {
  public static func evaluate(
    original: InsertionTarget,
    current: FocusedTargetFingerprint?
  ) -> TargetValidity {
    guard let current,
      current.applicationIdentifier == original.applicationIdentifier,
      current.elementToken == original.elementIdentifier
    else { return .changed }
    if let selection = original.selection, current.selection != selection { return .changed }
    return .valid
  }
}

public struct AccessibilityTargetCapabilities: Equatable, Sendable {
  public let role: String?
  public let subrole: String?
  public let isEnabled: Bool
  public let selectedTextSettable: Bool
  public let valueSettable: Bool

  public init(
    role: String?,
    subrole: String?,
    isEnabled: Bool,
    selectedTextSettable: Bool,
    valueSettable: Bool
  ) {
    self.role = role
    self.subrole = subrole
    self.isEnabled = isEnabled
    self.selectedTextSettable = selectedTextSettable
    self.valueSettable = valueSettable
  }
}

public enum AccessibilityTargetAccess: Equatable, Sendable {
  case direct
  case pasteOnly
  case secure
  case unsupported
}

public enum AccessibilityTargetPolicy {
  /// Secure classification uses metadata only and must run before any value/range reads.
  public static func isSecure(role: String?, subrole: String?) -> Bool {
    role == "AXSecureTextField" || subrole == "AXSecureTextField"
  }

  public static func access(
    for capabilities: AccessibilityTargetCapabilities
  ) -> AccessibilityTargetAccess {
    if isSecure(role: capabilities.role, subrole: capabilities.subrole) { return .secure }
    guard capabilities.isEnabled else { return .unsupported }
    if capabilities.selectedTextSettable { return .direct }

    let textRoles = ["AXTextArea", "AXTextField", "AXComboBox", "AXSearchField"]
    return capabilities.valueSettable && textRoles.contains(capabilities.role ?? "")
      ? .pasteOnly
      : .unsupported
  }
}

enum DirectInsertionVerification {
  static func wasApplied(
    originalSelection: TextSelection,
    originalCharacterCount: Int,
    insertedUTF16Count: Int,
    resultingSelection: TextSelection?,
    resultingCharacterCount: Int?
  ) -> Bool {
    let expectedCharacterCount =
      originalCharacterCount - originalSelection.length
      + insertedUTF16Count
    guard resultingCharacterCount == expectedCharacterCount else { return false }
    if expectedCharacterCount != originalCharacterCount { return true }
    return resultingSelection
      == TextSelection(location: originalSelection.location + insertedUTF16Count, length: 0)
  }
}
