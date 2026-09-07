import DictationCore
import Testing

@testable import SystemIntegration

@Suite("Indicator presentation")
struct IndicatorPolicyTests {
  @Test("every domain state maps to transcript-free presentation")
  func allStates() {
    let states: [IndicatorState] = [
      .ready, .unavailableSecureTarget, .recording(audioActivity: 0.8),
      .approachingRecordingLimit(audioActivity: 0.2), .finalizingRecognition,
      .cleaning, .delivering, .success, .rawTranscriptFallback,
      .oversizedFallback, .recognitionFallback, .copiedBecauseTargetChanged,
      .copiedBecauseNoTarget,
      .failure(.noUsableText), .failure(.recording), .failure(.delivery), .cancelled,
    ]

    let visuals = states.map(IndicatorVisual.init)
    #expect(visuals.count == states.count)
    #expect(visuals.allSatisfy { $0.accessibilityDescription.isEmpty == false })
    #expect(visuals[2].audioActivity == 0.8)
  }

  @Test("a dictation left on the clipboard does not look like one that was inserted")
  func clipboardResultsAreDistinctFromInsertedFallbacks() {
    // Both reached the clipboard, so both still need the person to paste.
    #expect(IndicatorVisual(.copiedBecauseNoTarget).tone == .copied)
    #expect(IndicatorVisual(.copiedBecauseTargetChanged).tone == .copied)

    // These landed in the target; nothing is left for the person to do.
    #expect(IndicatorVisual(.rawTranscriptFallback).tone == .fallback)
    #expect(IndicatorVisual(.oversizedFallback).tone == .fallback)
    #expect(IndicatorVisual(.recognitionFallback).tone == .fallback)
  }

  @Test("reaching the clipboard is never presented as a failure")
  func clipboardResultsAreNotFailures() {
    #expect(IndicatorVisual(.copiedBecauseNoTarget).tone != .failure)
    #expect(IndicatorVisual(.copiedBecauseTargetChanged).tone != .failure)
  }
}
