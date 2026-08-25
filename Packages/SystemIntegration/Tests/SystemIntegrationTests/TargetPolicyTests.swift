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
}
