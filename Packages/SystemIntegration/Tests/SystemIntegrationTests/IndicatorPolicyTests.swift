import DictationCore
import Testing

@testable import SystemIntegration

@Suite("Indicator presentation")
struct IndicatorPolicyTests {
  private static let everyState: [IndicatorState] = [
    .ready, .unavailableSecureTarget, .recording(audioActivity: 0.8),
    .approachingRecordingLimit(audioActivity: 0.2), .finalizingRecognition,
    .cleaning, .delivering, .success, .rawTranscriptFallback,
    .oversizedFallback, .recognitionFallback, .copiedBecauseTargetChanged,
    .copiedBecauseNoTarget,
    .failure(.noUsableText), .failure(.recording), .failure(.delivery), .cancelled,
  ]

  @Test("every domain state maps to a shape and never carries transcript text")
  func everyStateHasATranscriptFreeShape() {
    let transcript = "the quick brown fox jumped over the lazy dog"
    let visuals = IndicatorPolicyTests.everyState.map(IndicatorVisual.init)

    #expect(visuals.count == IndicatorPolicyTests.everyState.count)
    #expect(visuals.allSatisfy { $0.accessibilityDescription.isEmpty == false })
    // The toast vocabulary is closed: only the fixed strings below may ever appear.
    let permitted: Set<String> = [
      "Not available in a password field", "Thirty seconds left", "Copied to clipboard",
      "Dictation failed",
    ]
    #expect(visuals.compactMap(\.toast).allSatisfy(permitted.contains))
    #expect(visuals.contains { $0.toast?.contains(transcript) == true } == false)
    #expect(visuals.contains { $0.accessibilityDescription.contains(transcript) } == false)
  }

  @Test("only the four non-obvious outcomes speak, and they speak exactly these words")
  func speakingStates() {
    #expect(IndicatorVisual(.unavailableSecureTarget).toast == "Not available in a password field")
    #expect(
      IndicatorVisual(.approachingRecordingLimit(audioActivity: 0.4)).toast == "Thirty seconds left")
    #expect(IndicatorVisual(.copiedBecauseTargetChanged).toast == "Copied to clipboard")
    #expect(IndicatorVisual(.copiedBecauseNoTarget).toast == "Copied to clipboard")
    #expect(IndicatorVisual(.failure(.delivery)).toast == "Dictation failed")
  }

  @Test("an outcome the person can already see on screen stays silent")
  func silentStates() {
    // Deliberate: the inserted text is visible in the target, so a toast would nag on the most
    // common path of all. If this test fails because someone added a "Dictation inserted" toast,
    // the toast is the bug.
    #expect(IndicatorVisual(.success).toast == nil)
    #expect(IndicatorVisual(.rawTranscriptFallback).toast == nil)
    #expect(IndicatorVisual(.oversizedFallback).toast == nil)
    #expect(IndicatorVisual(.recognitionFallback).toast == nil)
    #expect(IndicatorVisual(.ready).toast == nil)
    #expect(IndicatorVisual(.cancelled).toast == nil)
    #expect(IndicatorVisual(.recording(audioActivity: 0.5)).toast == nil)
    #expect(IndicatorVisual(.finalizingRecognition).toast == nil)
    #expect(IndicatorVisual(.cleaning).toast == nil)
    #expect(IndicatorVisual(.delivering).toast == nil)
  }

  @Test("both recording states carry the live level through to the waveform")
  func recordingStatesRenderAWaveform() {
    #expect(IndicatorVisual(.recording(audioActivity: 0.8)).shape == .waveform(level: 0.8))
    #expect(IndicatorVisual(.recording(audioActivity: nil)).shape == .waveform(level: nil))
    #expect(
      IndicatorVisual(.approachingRecordingLimit(audioActivity: 0.2)).shape
        == .waveform(level: 0.2))
    #expect(
      IndicatorVisual(.approachingRecordingLimit(audioActivity: nil)).shape
        == .waveform(level: nil))
  }

  @Test("work in progress spins; everything else collapses to a sliver")
  func workingAndRestingShapes() {
    #expect(IndicatorVisual(.finalizingRecognition).shape == .spinner)
    #expect(IndicatorVisual(.cleaning).shape == .spinner)
    #expect(IndicatorVisual(.delivering).shape == .spinner)

    let collapsed: [IndicatorState] = [
      .ready, .unavailableSecureTarget, .success, .rawTranscriptFallback, .oversizedFallback,
      .recognitionFallback, .copiedBecauseTargetChanged, .copiedBecauseNoTarget,
      .failure(.noUsableText), .cancelled,
    ]
    #expect(collapsed.allSatisfy { IndicatorVisual($0).shape == .collapsed })
  }
}
