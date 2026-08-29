import AppKit

/// Counts Accessibility value reads observed by an instrumented control.
///
/// The Accessibility protocol methods are invoked on the main thread, but the counter is lock
/// protected anyway so that a read arriving on a framework thread can never corrupt the tally.
final class AccessibilityReadCounter: @unchecked Sendable {
  private let lock = NSLock()
  private var count = 0

  func record() {
    lock.withLock { count += 1 }
  }

  var observedReads: Int {
    lock.withLock { count }
  }
}

/// An `NSTextField` that tallies Accessibility reads of its value.
///
/// Only `accessibilityValue()` is overridden. AppKit resolves some text attributes through the
/// legacy attribute path, and merely *declaring* an override such as
/// `accessibilityNumberOfCharacters()` makes the control answer from `NSView`'s default
/// implementation instead, which reports 0 for a field being edited. That silently changed what
/// the production delivery path measured, so the instrument is kept to the one method
/// `NSTextField` genuinely implements. `borderedTextField` is deliberately left uninstrumented so
/// the driver can A/B the two and prove the instrument changes nothing.
final class InstrumentedTextField: NSTextField {
  let readCounter = AccessibilityReadCounter()

  override func accessibilityValue() -> String? {
    readCounter.record()
    return super.accessibilityValue()
  }
}

/// An `NSSecureTextField` instrumented across every textual Accessibility read.
///
/// Poptart must refuse this control outright, so the counter turns "we never read it" from a code
/// reading into a measurement. The wider set of overrides is safe here because the secure
/// classification is decided from role and subrole alone, which these methods cannot affect.
final class InstrumentedSecureTextField: NSSecureTextField {
  let readCounter = AccessibilityReadCounter()

  override func accessibilityValue() -> String? {
    readCounter.record()
    return super.accessibilityValue()
  }

  override func accessibilityNumberOfCharacters() -> Int {
    readCounter.record()
    return super.accessibilityNumberOfCharacters()
  }

  override func accessibilitySelectedText() -> String? {
    readCounter.record()
    return super.accessibilitySelectedText()
  }

  override func accessibilityString(for range: NSRange) -> String? {
    readCounter.record()
    return super.accessibilityString(for: range)
  }

  override func accessibilityAttributedString(for range: NSRange) -> NSAttributedString? {
    readCounter.record()
    return super.accessibilityAttributedString(for: range)
  }
}
