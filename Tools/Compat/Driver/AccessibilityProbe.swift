import AppKit
import ApplicationServices
import CompatChannel
import DictationCore
import Foundation
import SystemIntegration

/// Read-only Accessibility observation used to describe what the production capture path saw.
///
/// Nothing here duplicates capture or delivery: the driver reads element metadata so that the
/// report can name the role, subrole and settability behind a classification, and the
/// classification itself is produced by the shipping `AccessibilityTargetPolicy`.
enum AccessibilityProbe {
  static let identifierAttribute = "AXIdentifier"
  static let domIdentifierAttribute = "AXDOMIdentifier"

  static func isTrusted() -> Bool {
    AXIsProcessTrusted()
  }

  @discardableResult
  static func requestTrust() -> Bool {
    AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
  }

  static func copiedAttribute(_ name: String, of element: AXUIElement) -> CFTypeRef? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else {
      return nil
    }
    return value
  }

  static func string(_ name: String, of element: AXUIElement) -> String? {
    copiedAttribute(name, of: element) as? String
  }

  static func integer(_ name: String, of element: AXUIElement) -> Int? {
    (copiedAttribute(name, of: element) as? NSNumber)?.intValue
  }

  static func boolean(_ name: String, of element: AXUIElement) -> Bool? {
    (copiedAttribute(name, of: element) as? NSNumber)?.boolValue
  }

  static func isSettable(_ name: String, of element: AXUIElement) -> Bool {
    var settable = DarwinBoolean(false)
    return AXUIElementIsAttributeSettable(element, name as CFString, &settable) == .success
      && settable.boolValue
  }

  /// The focused element exactly as `AccessibilityTextService` resolves it: system-wide focused
  /// application, then that application's focused UI element.
  static func systemFocusedElement() -> (element: AXUIElement, processIdentifier: pid_t)? {
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
    guard AXUIElementGetPid(application, &pid) == .success else { return nil }
    return (element, pid)
  }

  static func attributeNames(of element: AXUIElement) -> [String] {
    var names: CFArray?
    guard AXUIElementCopyAttributeNames(element, &names) == .success,
      let list = names as? [String]
    else { return [] }
    return list
  }

  /// Whether the element implements an attribute at all, independently of its value. This is how
  /// the shipping classifier detects `AXDOMIdentifier`, so the probe must ask the same question:
  /// a web element whose DOM node has no `id` still implements the attribute, as an empty string.
  static func implementsAttribute(_ name: String, of element: AXUIElement) -> Bool {
    attributeNames(of: element).contains(name)
  }

  static func capabilities(of element: AXUIElement) -> AccessibilityTargetCapabilities {
    .init(
      role: string(kAXRoleAttribute, of: element),
      subrole: string(kAXSubroleAttribute, of: element),
      isEnabled: boolean(kAXEnabledAttribute, of: element) ?? true,
      selectedTextSettable: isSettable(kAXSelectedTextAttribute, of: element),
      valueSettable: isSettable(kAXValueAttribute, of: element),
      hasWebDOMIdentifier: implementsAttribute(
        AccessibilityTargetPolicy.webDOMIdentifierAttribute, of: element)
    )
  }

  /// The bounded state the shipping delivery reads back to confirm an insertion.
  static func textState(of element: AXUIElement) -> TargetTextState {
    .init(
      characterCount: integer(kAXNumberOfCharactersAttribute, of: element),
      selection: selectedRange(of: element)
    )
  }

  static func identifier(of element: AXUIElement) -> String? {
    string(identifierAttribute, of: element) ?? string(domIdentifierAttribute, of: element)
  }

  static func parent(of element: AXUIElement) -> AXUIElement? {
    guard let value = copiedAttribute(kAXParentAttribute, of: element),
      CFGetTypeID(value) == AXUIElementGetTypeID()
    else { return nil }
    return unsafeDowncast(value as AnyObject, to: AXUIElement.self)
  }

  static func children(of element: AXUIElement) -> [AXUIElement] {
    guard let value = copiedAttribute(kAXChildrenAttribute, of: element) else { return [] }
    guard let array = value as? [AnyObject] else { return [] }
    return array.compactMap { child in
      CFGetTypeID(child) == AXUIElementGetTypeID()
        ? unsafeDowncast(child, to: AXUIElement.self) : nil
    }
  }

  /// Breadth-first search of an application's element tree, matching either the AppKit
  /// `AXIdentifier` or WebKit's `AXDOMIdentifier`.
  static func findElement(
    identifier target: String,
    inApplication pid: pid_t,
    nodeBudget: Int = 4000
  ) -> AXUIElement? {
    var queue = [AXUIElementCreateApplication(pid)]
    var visited = 0
    while !queue.isEmpty, visited < nodeBudget {
      let element = queue.removeFirst()
      visited += 1
      if identifier(of: element) == target { return element }
      queue.append(contentsOf: children(of: element))
    }
    return nil
  }

  static func value(of element: AXUIElement) -> String? {
    guard let raw = copiedAttribute(kAXValueAttribute, of: element) else { return nil }
    if let text = raw as? String { return text }
    if let attributed = raw as? NSAttributedString { return attributed.string }
    return nil
  }

  static func selectedRange(of element: AXUIElement) -> TextSelection? {
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

  static func frame(of element: AXUIElement) -> CompatRect? {
    guard let positionValue = copiedAttribute(kAXPositionAttribute, of: element),
      CFGetTypeID(positionValue) == AXValueGetTypeID(),
      let sizeValue = copiedAttribute(kAXSizeAttribute, of: element),
      CFGetTypeID(sizeValue) == AXValueGetTypeID()
    else { return nil }
    var point = CGPoint.zero
    var size = CGSize.zero
    guard
      AXValueGetValue(unsafeDowncast(positionValue as AnyObject, to: AXValue.self), .cgPoint, &point),
      AXValueGetValue(unsafeDowncast(sizeValue as AnyObject, to: AXValue.self), .cgSize, &size)
    else { return nil }
    return CompatRect(x: point.x, y: point.y, width: size.width, height: size.height)
  }

  /// Marks an element as focused through Accessibility. Used only as a fallback when the host's
  /// own first-responder path does not move Accessibility focus.
  @discardableResult
  static func setFocused(_ element: AXUIElement) -> Bool {
    AXUIElementSetAttributeValue(element, kAXFocusedAttribute as CFString, kCFBooleanTrue)
      == .success
  }
}

extension CompatRect {
  var asCGRect: CGRect { CGRect(x: x, y: y, width: width, height: height) }

  /// Fraction of `self` covered by `other`, used to match an Accessibility element against the
  /// host's own report of where a control is on screen.
  func overlapFraction(with other: CompatRect) -> Double {
    let intersection = asCGRect.intersection(other.asCGRect)
    guard !intersection.isNull, asCGRect.width > 0, asCGRect.height > 0 else { return 0 }
    return (intersection.width * intersection.height) / (asCGRect.width * asCGRect.height)
  }
}
