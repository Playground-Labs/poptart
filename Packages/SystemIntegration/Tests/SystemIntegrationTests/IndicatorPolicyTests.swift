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
      .failure(.noUsableText), .failure(.recording), .failure(.delivery), .cancelled,
    ]

    let visuals = states.map(IndicatorVisual.init)
    #expect(visuals.count == states.count)
    #expect(visuals.allSatisfy { $0.accessibilityDescription.isEmpty == false })
    #expect(visuals.allSatisfy { $0.transcript == nil })
    #expect(visuals[2].audioActivity == 0.8)
  }
}
