import DictationCore
import Foundation
import Testing

@testable import SystemIntegration

@Suite("Insertion Target policy")
struct TargetPolicyTests {
  @Test("secure target metadata is recognized without field contents")
  func secureMetadata() {
    #expect(AccessibilityTargetPolicy.isSecure(role: "AXSecureTextField", subrole: nil))
    #expect(AccessibilityTargetPolicy.isSecure(role: "AXTextField", subrole: "AXSecureTextField"))
    #expect(!AccessibilityTargetPolicy.isSecure(role: "AXTextField", subrole: nil))
  }

  @Test(
    "native, paste-only, secure, and non-text controls select an application-independent path",
    arguments: [
      (
        AccessibilityTargetCapabilities(
          role: "AXTextArea", subrole: nil, isEnabled: true,
          selectedTextSettable: true, valueSettable: true),
        AccessibilityTargetAccess.direct
      ),
      (
        AccessibilityTargetCapabilities(
          role: "AXTextField", subrole: nil, isEnabled: true,
          selectedTextSettable: false, valueSettable: true),
        AccessibilityTargetAccess.pasteOnly
      ),
      (
        AccessibilityTargetCapabilities(
          role: "AXSecureTextField", subrole: nil, isEnabled: true,
          selectedTextSettable: true, valueSettable: true),
        AccessibilityTargetAccess.secure
      ),
      (
        AccessibilityTargetCapabilities(
          role: "AXButton", subrole: nil, isEnabled: true,
          selectedTextSettable: false, valueSettable: true),
        AccessibilityTargetAccess.unsupported
      ),
    ]
  )
  func targetAccess(
    capabilities: AccessibilityTargetCapabilities,
    expected: AccessibilityTargetAccess
  ) {
    #expect(AccessibilityTargetPolicy.access(for: capabilities) == expected)
  }

  @Test("context ranges are bounded around the selection")
  func boundedRanges() {
    let ranges = TargetContextBounds(maximumUTF16CodeUnitsPerSide: 4)
      .ranges(characterCount: 20, selection: .init(location: 8, length: 3))

    #expect(ranges.before == NSRange(location: 4, length: 4))
    #expect(ranges.selected == NSRange(location: 8, length: 3))
    #expect(ranges.after == NSRange(location: 11, length: 4))
  }

  @Test("selected context is bounded without changing the captured selection")
  func boundedSelectionContext() {
    let ranges = TargetContextBounds(maximumUTF16CodeUnitsPerSide: 4)
      .ranges(characterCount: 30, selection: .init(location: 8, length: 12))

    #expect(ranges.selected == NSRange(location: 8, length: 4))
    #expect(ranges.capturedSelection == TextSelection(location: 8, length: 12))
  }

  @Test(arguments: [
    (
      FocusedTargetFingerprint(
        applicationIdentifier: "labs.playground.Poptart", elementToken: "a",
        selection: .init(location: 4, length: 0)), TargetValidity.valid
    ),
    (
      FocusedTargetFingerprint(
        applicationIdentifier: "other", elementToken: "a", selection: .init(location: 4, length: 0)),
      TargetValidity.changed
    ),
    (
      FocusedTargetFingerprint(
        applicationIdentifier: "labs.playground.Poptart", elementToken: "b",
        selection: .init(location: 4, length: 0)), TargetValidity.changed
    ),
    (
      FocusedTargetFingerprint(
        applicationIdentifier: "labs.playground.Poptart", elementToken: "a",
        selection: .init(location: 5, length: 0)), TargetValidity.changed
    ),
  ])
  func revalidation(current: FocusedTargetFingerprint, expected: TargetValidity) {
    let original = InsertionTarget(
      applicationIdentifier: "labs.playground.Poptart",
      elementIdentifier: "a",
      selection: .init(location: 4, length: 0)
    )
    #expect(TargetRevalidationPolicy.evaluate(original: original, current: current) == expected)
  }

  @Test("a paste-only target revalidates by application and element identity")
  func pasteOnlyRevalidation() {
    let original = InsertionTarget(
      applicationIdentifier: "labs.playground.Poptart",
      elementIdentifier: "editor",
      selection: nil
    )
    let sameTarget = FocusedTargetFingerprint(
      applicationIdentifier: "labs.playground.Poptart",
      elementToken: "editor",
      selection: .init(location: 12, length: 0)
    )
    let otherTarget = FocusedTargetFingerprint(
      applicationIdentifier: "labs.playground.Poptart",
      elementToken: "other",
      selection: nil
    )

    #expect(TargetRevalidationPolicy.evaluate(original: original, current: sameTarget) == .valid)
    #expect(TargetRevalidationPolicy.evaluate(original: original, current: otherTarget) == .changed)
  }

  @Test("a web-hosted control is classified paste-only even though it claims to be settable")
  func webHostedControlIsDemoted() {
    // Measured: `<input type=text>`, `<textarea>` and `contenteditable` all report
    // AXSelectedTextSettable = true, then ignore AXUIElementSetAttributeValue and return success.
    for role in ["AXTextField", "AXTextArea"] {
      let webHosted = AccessibilityTargetCapabilities(
        role: role, subrole: nil, isEnabled: true,
        selectedTextSettable: true, valueSettable: true, hasWebDOMIdentifier: true)

      #expect(AccessibilityTargetPolicy.access(for: webHosted) == .pasteOnly)
    }
  }

  @Test("a native control keeps the direct path because it does not implement AXDOMIdentifier")
  func nativeControlIsNotDemoted() {
    for role in ["AXTextField", "AXTextArea", "AXComboBox"] {
      let native = AccessibilityTargetCapabilities(
        role: role, subrole: nil, isEnabled: true,
        selectedTextSettable: true, valueSettable: true, hasWebDOMIdentifier: false)

      #expect(AccessibilityTargetPolicy.access(for: native) == .direct)
    }
  }

  @Test("a web-hosted password field is still refused before anything else is considered")
  func webHostedSecureFieldStaysSecure() {
    let webPassword = AccessibilityTargetCapabilities(
      role: "AXTextField", subrole: "AXSecureTextField", isEnabled: true,
      selectedTextSettable: true, valueSettable: true, hasWebDOMIdentifier: true)

    #expect(AccessibilityTargetPolicy.access(for: webPassword) == .secure)
  }

  @Test("a search field is matched by the role it really reports, not by a subrole role name")
  func searchFieldUsesItsRealRole() {
    // A real NSSearchField reports role AXTextField with subrole AXSearchField, so the paste-only
    // role list covers it. Nothing reports "AXSearchField" as a role.
    let pasteOnlySearchField = AccessibilityTargetCapabilities(
      role: "AXTextField", subrole: "AXSearchField", isEnabled: true,
      selectedTextSettable: false, valueSettable: true)
    let settableSearchField = AccessibilityTargetCapabilities(
      role: "AXTextField", subrole: "AXSearchField", isEnabled: true,
      selectedTextSettable: true, valueSettable: true)

    #expect(AccessibilityTargetPolicy.access(for: pasteOnlySearchField) == .pasteOnly)
    #expect(AccessibilityTargetPolicy.access(for: settableSearchField) == .direct)
  }

  @Test("an Accessibility write that returns success and moves nothing is a named no-op")
  func silentNoOpDirectWrite() {
    let original = TextSelection(location: 4, length: 0)

    let outcome = DirectInsertionVerification.outcome(
      writeSucceeded: true,
      originalSelection: original,
      originalCharacterCount: 10,
      insertedUTF16Count: 5,
      resultingSelection: original,
      resultingCharacterCount: 10
    )

    #expect(outcome == .reportedSuccessButTargetUnchanged)
    #expect(outcome.nextStep == .fallBackToClipboardPaste)
  }

  @Test("a verified direct write completes the delivery")
  func appliedDirectWrite() {
    let outcome = DirectInsertionVerification.outcome(
      writeSucceeded: true,
      originalSelection: .init(location: 4, length: 0),
      originalCharacterCount: 10,
      insertedUTF16Count: 5,
      resultingSelection: .init(location: 9, length: 0),
      resultingCharacterCount: 15
    )

    #expect(outcome == .applied)
    #expect(outcome.nextStep == .reportInserted)
  }

  @Test(
    "every unverified direct outcome falls back to the clipboard by design",
    arguments: [
      DirectInsertionOutcome.writeRefused,
      DirectInsertionOutcome.reportedSuccessButTargetUnchanged,
      DirectInsertionOutcome.reportedSuccessButUnverified,
    ]
  )
  func unverifiedDirectOutcomesFallBack(outcome: DirectInsertionOutcome) {
    #expect(outcome.nextStep == .fallBackToClipboardPaste)
  }

  @Test("a refused Accessibility write is distinguished from a silent no-op")
  func refusedDirectWrite() {
    let original = TextSelection(location: 4, length: 0)

    #expect(
      DirectInsertionVerification.outcome(
        writeSucceeded: false,
        originalSelection: original,
        originalCharacterCount: 10,
        insertedUTF16Count: 5,
        resultingSelection: original,
        resultingCharacterCount: 10
      ) == .writeRefused)
  }

  @Test("an unreadable target after a direct write is unverified rather than applied")
  func unreadableDirectWrite() {
    #expect(
      DirectInsertionVerification.outcome(
        writeSucceeded: true,
        originalSelection: .init(location: 4, length: 0),
        originalCharacterCount: 10,
        insertedUTF16Count: 5,
        resultingSelection: nil,
        resultingCharacterCount: nil
      ) == .reportedSuccessButUnverified)
  }
}
