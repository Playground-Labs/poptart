import AppKit
import ApplicationServices
import DictationCore
import Foundation

public protocol AccessibilityPermission: Sendable {
  func isGranted() -> Bool
  func request() -> Bool
}

public struct SystemAccessibilityPermission: AccessibilityPermission {
  public init() {}

  public func isGranted() -> Bool {
    AXIsProcessTrusted()
  }

  public func request() -> Bool {
    let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
    return AXIsProcessTrustedWithOptions(options)
  }
}

/// Accessibility-first target capture and delivery. Captured AX elements remain ephemeral and in memory.
public final class AccessibilityTextService: InsertionTargetBoundary, TextDeliveryBoundary,
  @unchecked Sendable
{
  private struct CapturedTarget {
    let dictationID: DictationID
    let element: AXUIElement
    let applicationIdentifier: String
    let selection: TextSelection?
    let characterCount: Int?
    let directInsertionAllowed: Bool
  }

  private let permission: any AccessibilityPermission
  private let contextBounds: TargetContextBounds
  private let clipboard: ClipboardPasteCoordinator
  private let lock = NSLock()
  private var capturedTargets: [String: CapturedTarget] = [:]

  public init(
    permission: any AccessibilityPermission = SystemAccessibilityPermission(),
    contextBounds: TargetContextBounds = .init(),
    clipboard: ClipboardPasteCoordinator = .init()
  ) {
    self.permission = permission
    self.contextBounds = contextBounds
    self.clipboard = clipboard
  }

  @discardableResult
  public func requestPermission() -> Bool {
    permission.request()
  }

  public func captureTarget(for id: DictationID) async -> Result<
    DictationTargetCapture, TargetCaptureFailure
  > {
    guard permission.isGranted() else { return .failure(.permissionDenied) }
    guard let focused = Self.focusedElement() else { return .failure(.noEditableTarget) }

    // Secure classification deliberately precedes every text or range query.
    let role = Self.stringAttribute(kAXRoleAttribute, of: focused.element)
    let subrole = Self.stringAttribute(kAXSubroleAttribute, of: focused.element)
    let token = UUID().uuidString
    if AccessibilityTargetPolicy.isSecure(role: role, subrole: subrole) {
      return .success(
        .secure(
          applicationIdentifier: focused.applicationIdentifier,
          elementIdentifier: token
        ))
    }

    let access = AccessibilityTargetPolicy.access(
      for: .init(
        role: role,
        subrole: subrole,
        isEnabled: Self.booleanAttribute(kAXEnabledAttribute, of: focused.element) ?? true,
        selectedTextSettable: Self.isAttributeSettable(
          kAXSelectedTextAttribute, of: focused.element),
        valueSettable: Self.isAttributeSettable(kAXValueAttribute, of: focused.element)
      ))
    guard access == .direct || access == .pasteOnly else {
      return .failure(.noEditableTarget)
    }

    let selection = Self.selectedRange(of: focused.element)
    let characterCount = Self.integerAttribute(
      kAXNumberOfCharactersAttribute, of: focused.element)
    let context =
      selection.flatMap { selection in
        characterCount.flatMap { characterCount in
          Self.context(
            of: focused.element,
            applicationIdentifier: focused.applicationIdentifier,
            characterCount: characterCount,
            selection: selection,
            bounds: contextBounds
          )
        }
      }
      ?? TargetContext(
        applicationIdentifier: focused.applicationIdentifier,
        applicationCategory: Self.category(for: focused.applicationIdentifier),
        textBeforeCursor: "",
        textAfterCursor: "",
        selectedText: nil
      )

    let target = InsertionTarget(
      applicationIdentifier: focused.applicationIdentifier,
      elementIdentifier: token,
      selection: selection
    )
    lock.withLock {
      capturedTargets[token] = .init(
        dictationID: id,
        element: focused.element,
        applicationIdentifier: focused.applicationIdentifier,
        selection: selection,
        characterCount: characterCount,
        directInsertionAllowed: access == .direct
      )
    }
    return .success(.editable(target: target, context: context))
  }

  public func revalidateTarget(_ request: TargetRevalidationRequest) async -> TargetValidity {
    revalidate(request.originalTarget)
  }

  public func deliver(_ request: DeliveryRequest) async -> DeliveryResult {
    guard revalidate(request.target) == .valid,
      let captured = lock.withLock({ capturedTargets[request.target.elementIdentifier] })
    else { return .failed(.accessibilityAndPasteFailed) }

    let directWasApplied: Bool
    if captured.directInsertionAllowed,
      let selection = captured.selection,
      let characterCount = captured.characterCount
    {
      let direct = AXUIElementSetAttributeValue(
        captured.element,
        kAXSelectedTextAttribute as CFString,
        request.text as CFTypeRef
      )
      directWasApplied =
        direct == .success
        && DirectInsertionVerification.wasApplied(
          originalSelection: selection,
          originalCharacterCount: characterCount,
          insertedUTF16Count: request.text.utf16.count,
          resultingSelection: Self.selectedRange(of: captured.element),
          resultingCharacterCount: Self.integerAttribute(
            kAXNumberOfCharactersAttribute, of: captured.element)
        )
    } else {
      directWasApplied = false
    }
    if directWasApplied {
      removeCapture(for: request.target)
      return .inserted(.accessibility)
    }

    // Revalidate again after the failed write to close the target-change race before paste.
    guard revalidate(request.target) == .valid else {
      return .failed(.accessibilityAndPasteFailed)
    }
    let result = await clipboard.pastePreservingClipboard(
      text: request.text, deadline: request.deadline)
    removeCapture(for: request.target)
    return result
  }

  public func copyToClipboard(_ request: ClipboardRequest) async -> DeliveryResult {
    let result = await clipboard.replaceClipboard(text: request.text)
    removeCaptures(for: request.id)
    return result
  }

  public func cancelDelivery(for id: DictationID) async {
    removeCaptures(for: id)
  }

  private func revalidate(_ target: InsertionTarget) -> TargetValidity {
    guard permission.isGranted(),
      let captured = lock.withLock({ capturedTargets[target.elementIdentifier] }),
      let focused = Self.focusedElement(),
      focused.applicationIdentifier == captured.applicationIdentifier,
      CFEqual(focused.element, captured.element)
    else { return .changed }

    let current = FocusedTargetFingerprint(
      applicationIdentifier: focused.applicationIdentifier,
      elementToken: target.elementIdentifier,
      selection: Self.selectedRange(of: focused.element)
    )
    return TargetRevalidationPolicy.evaluate(original: target, current: current)
  }

  private func removeCapture(for target: InsertionTarget) {
    _ = lock.withLock { capturedTargets.removeValue(forKey: target.elementIdentifier) }
  }

  private func removeCaptures(for id: DictationID) {
    lock.withLock {
      capturedTargets = capturedTargets.filter { $0.value.dictationID != id }
    }
  }

  private static func focusedElement() -> (element: AXUIElement, applicationIdentifier: String)? {
    let system = AXUIElementCreateSystemWide()
    guard let applicationValue = copiedAttribute(kAXFocusedApplicationAttribute, of: system),
      CFGetTypeID(applicationValue) == AXUIElementGetTypeID()
    else { return nil }
    let application = unsafeDowncast(applicationValue as AnyObject, to: AXUIElement.self)
    guard let elementValue = copiedAttribute(kAXFocusedUIElementAttribute, of: application),
      CFGetTypeID(elementValue) == AXUIElementGetTypeID()
    else { return nil }
    let element = unsafeDowncast(elementValue as AnyObject, to: AXUIElement.self)

    var pid: pid_t = 0
    guard AXUIElementGetPid(application, &pid) == .success,
      let identifier = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier
    else { return nil }
    return (element, identifier)
  }

  private static func copiedAttribute(_ name: String, of element: AXUIElement) -> CFTypeRef? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else {
      return nil
    }
    return value
  }

  private static func stringAttribute(_ name: String, of element: AXUIElement) -> String? {
    copiedAttribute(name, of: element) as? String
  }

  private static func integerAttribute(_ name: String, of element: AXUIElement) -> Int? {
    (copiedAttribute(name, of: element) as? NSNumber)?.intValue
  }

  private static func booleanAttribute(_ name: String, of element: AXUIElement) -> Bool? {
    (copiedAttribute(name, of: element) as? NSNumber)?.boolValue
  }

  private static func selectedRange(of element: AXUIElement) -> TextSelection? {
    guard let rawValue = copiedAttribute(kAXSelectedTextRangeAttribute, of: element),
      CFGetTypeID(rawValue) == AXValueGetTypeID()
    else { return nil }
    let raw = unsafeDowncast(rawValue as AnyObject, to: AXValue.self)
    guard AXValueGetType(raw) == .cfRange else { return nil }
    var range = CFRange()
    guard AXValueGetValue(raw, .cfRange, &range), range.location >= 0, range.length >= 0 else {
      return nil
    }
    return .init(location: range.location, length: range.length)
  }

  private static func string(in range: NSRange, of element: AXUIElement) -> String? {
    var cfRange = CFRange(location: range.location, length: range.length)
    guard let parameter = AXValueCreate(.cfRange, &cfRange) else { return nil }
    var value: CFTypeRef?
    let result = AXUIElementCopyParameterizedAttributeValue(
      element,
      kAXStringForRangeParameterizedAttribute as CFString,
      parameter,
      &value
    )
    guard result == .success else { return nil }
    return value as? String
  }

  private static func isAttributeSettable(_ name: String, of element: AXUIElement) -> Bool {
    var settable = DarwinBoolean(false)
    return AXUIElementIsAttributeSettable(
      element,
      name as CFString,
      &settable
    ) == .success && settable.boolValue
  }

  private static func context(
    of element: AXUIElement,
    applicationIdentifier: String,
    characterCount: Int,
    selection: TextSelection,
    bounds: TargetContextBounds
  ) -> TargetContext? {
    let ranges = bounds.ranges(characterCount: characterCount, selection: selection)
    guard let before = string(in: ranges.before, of: element),
      let after = string(in: ranges.after, of: element)
    else { return nil }
    let selected =
      ranges.selected.length == 0
      ? nil
      : string(in: ranges.selected, of: element)
    return .init(
      applicationIdentifier: applicationIdentifier,
      applicationCategory: category(for: applicationIdentifier),
      textBeforeCursor: before,
      textAfterCursor: after,
      selectedText: selected
    )
  }

  private static func category(for applicationIdentifier: String) -> ApplicationCategory {
    switch applicationIdentifier {
    case "com.apple.TextEdit", "com.microsoft.VSCode", "com.todesktop.230313mzl4w4u92":
      .textEditor
    case "com.apple.MobileSMS", "com.tinyspeck.slackmacgap", "com.hnc.Discord":
      .messaging
    case "com.apple.mail", "com.microsoft.Outlook":
      .email
    case "com.apple.Safari", "com.google.Chrome", "org.mozilla.firefox":
      .browser
    default:
      .other
    }
  }
}
