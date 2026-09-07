import DictationCore
import Foundation

public enum IndicatorTone: String, Equatable, Sendable {
  case neutral
  case active
  case warning
  case success
  case fallback
  /// The text is on the clipboard and the person has to paste it themselves. This is the only
  /// completion that leaves work undone, so it does not share the inserted fallbacks' tone.
  case copied
  case failure
}

public struct IndicatorVisual: Equatable, Sendable {
  public let tone: IndicatorTone
  public let audioActivity: Double?
  public let accessibilityDescription: String

  public init(_ state: IndicatorState) {
    switch state {
    case .ready:
      (tone, audioActivity, accessibilityDescription) = (.neutral, nil, "Poptart ready")
    case .unavailableSecureTarget:
      (tone, audioActivity, accessibilityDescription) = (
        .warning, nil, "Dictation unavailable in secure field"
      )
    case .recording(let activity):
      (tone, audioActivity, accessibilityDescription) = (.active, activity, "Recording")
    case .approachingRecordingLimit(let activity):
      (tone, audioActivity, accessibilityDescription) = (
        .warning, activity, "Recording limit approaching"
      )
    case .finalizingRecognition:
      (tone, audioActivity, accessibilityDescription) = (.active, nil, "Finalizing recognition")
    case .cleaning:
      (tone, audioActivity, accessibilityDescription) = (.active, nil, "Cleaning dictation")
    case .delivering:
      (tone, audioActivity, accessibilityDescription) = (.active, nil, "Delivering dictation")
    case .success:
      (tone, audioActivity, accessibilityDescription) = (.success, nil, "Dictation inserted")
    case .rawTranscriptFallback:
      (tone, audioActivity, accessibilityDescription) = (.fallback, nil, "Raw transcript inserted")
    case .oversizedFallback:
      (tone, audioActivity, accessibilityDescription) = (
        .fallback, nil, "Deterministic cleanup inserted"
      )
    case .recognitionFallback:
      (tone, audioActivity, accessibilityDescription) = (
        .fallback, nil, "Recognition hypothesis inserted"
      )
    case .copiedBecauseTargetChanged:
      (tone, audioActivity, accessibilityDescription) = (
        .copied, nil, "Target changed; dictation copied"
      )
    case .copiedBecauseNoTarget:
      (tone, audioActivity, accessibilityDescription) = (
        .copied, nil, "No text field; dictation copied"
      )
    case .failure:
      (tone, audioActivity, accessibilityDescription) = (.failure, nil, "Dictation failed")
    case .cancelled:
      (tone, audioActivity, accessibilityDescription) = (.neutral, nil, "Dictation cancelled")
    }
  }
}
