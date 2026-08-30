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
  /// Whether the element implements `AXDOMIdentifier`, the attribute web engines add to every
  /// DOM-backed element and that no AppKit control implements. It is the signal available at
  /// classification time that says "this control is a web page element".
  public let hasWebDOMIdentifier: Bool

  public init(
    role: String?,
    subrole: String?,
    isEnabled: Bool,
    selectedTextSettable: Bool,
    valueSettable: Bool,
    hasWebDOMIdentifier: Bool = false
  ) {
    self.role = role
    self.subrole = subrole
    self.isEnabled = isEnabled
    self.selectedTextSettable = selectedTextSettable
    self.valueSettable = valueSettable
    self.hasWebDOMIdentifier = hasWebDOMIdentifier
  }
}

public enum AccessibilityTargetAccess: Equatable, Sendable {
  case direct
  case pasteOnly
  case secure
  case unsupported
}

public enum AccessibilityTargetPolicy {
  /// The attribute web-engine-backed Accessibility elements carry. Measured present on all four
  /// WebKit controls and absent from all nine AppKit controls in the compatibility matrix, which
  /// is the evidence the demotion below rests on.
  ///
  /// Presence is what matters, not the value: an element whose DOM node has no `id` still
  /// implements the attribute and reports an empty string, so the check must be against the
  /// element's attribute list rather than against a copied value.
  public static let webDOMIdentifierAttribute = "AXDOMIdentifier"

  /// Secure classification uses metadata only and must run before any value/range reads.
  public static func isSecure(role: String?, subrole: String?) -> Bool {
    role == "AXSecureTextField" || subrole == "AXSecureTextField"
  }

  public static func access(
    for capabilities: AccessibilityTargetCapabilities
  ) -> AccessibilityTargetAccess {
    if isSecure(role: capabilities.role, subrole: capabilities.subrole) { return .secure }
    guard capabilities.isEnabled else { return .unsupported }
    if capabilities.selectedTextSettable {
      // Web-hosted editable elements advertise `AXSelectedTextSettable = true` and then ignore the
      // write. The compatibility harness measured `AXUIElementSetAttributeValue` returning
      // kAXErrorSuccess while the value and the selection both stayed put, on `<input type=text>`,
      // `<textarea>` and `contenteditable` alike. Paying for that write costs a cross-process
      // round trip and buys nothing, so a web-hosted element goes to the clipboard by design
      // rather than by falling through a failed verification.
      return capabilities.hasWebDOMIdentifier ? .pasteOnly : .direct
    }

    // Roles only. A real `NSSearchField` reports role `AXTextField` with subrole `AXSearchField`
    // (measured), so it is already covered by `AXTextField`; there is no control that reports
    // `AXSearchField` as its role.
    let textRoles = ["AXTextArea", "AXTextField", "AXComboBox"]
    return capabilities.valueSettable && textRoles.contains(capabilities.role ?? "")
      ? .pasteOnly
      : .unsupported
  }
}

/// What a direct `AXSelectedText` write actually achieved, as opposed to what it returned.
public enum DirectInsertionOutcome: String, Equatable, Sendable {
  /// The write returned success and the target moved the way an insertion moves a target.
  case applied
  /// `AXUIElementSetAttributeValue` itself refused the write.
  case writeRefused
  /// The write returned `kAXErrorSuccess` and the target did not move at all: a silent no-op.
  /// This is not a hypothetical - it is what every web-hosted editable control does, measured.
  case reportedSuccessButTargetUnchanged
  /// The write returned success and the target moved, but not into the shape this insertion
  /// would produce. Nothing can be concluded from it.
  case reportedSuccessButUnverified
}

extension DirectInsertionOutcome {
  /// Where the delivery goes next. Only a verified write completes a delivery; every other
  /// outcome deliberately continues to the clipboard paste, which carries its own read-back
  /// confirmation. The fall-through for `reportedSuccessButUnverified` is guarded by the
  /// revalidation the delivery performs before pasting: a target that moved is reported changed
  /// rather than pasted into twice.
  public var nextStep: DirectInsertionNextStep {
    self == .applied ? .reportInserted : .fallBackToClipboardPaste
  }
}

public enum DirectInsertionNextStep: Equatable, Sendable {
  case reportInserted
  case fallBackToClipboardPaste
}

public enum DirectInsertionVerification {
  public static func outcome(
    writeSucceeded: Bool,
    originalSelection: TextSelection,
    originalCharacterCount: Int,
    insertedUTF16Count: Int,
    resultingSelection: TextSelection?,
    resultingCharacterCount: Int?
  ) -> DirectInsertionOutcome {
    guard writeSucceeded else { return .writeRefused }
    let expectedCharacterCount =
      originalCharacterCount - originalSelection.length
      + insertedUTF16Count
    if resultingCharacterCount == expectedCharacterCount {
      if expectedCharacterCount != originalCharacterCount { return .applied }
      // A same-length replacement leaves the count where it was, so only the caret can decide.
      return resultingSelection
        == TextSelection(location: originalSelection.location + insertedUTF16Count, length: 0)
        ? .applied
        : .reportedSuccessButUnverified
    }
    if resultingCharacterCount == originalCharacterCount, resultingSelection == originalSelection {
      return .reportedSuccessButTargetUnchanged
    }
    return .reportedSuccessButUnverified
  }
}
