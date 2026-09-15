import DictationCore
import Foundation

/// The indicator says what it is doing by changing silhouette, never by changing hue. Colour is
/// unreliable as the sole carrier of meaning — it is invisible to a person who does not know the
/// legend, and to one who cannot separate the hues at all.
public enum IndicatorShape: Equatable, Sendable {
  /// A blank sliver: present, saying nothing.
  case collapsed
  case waveform(level: Double?)
  case spinner
}

public struct IndicatorVisual: Equatable, Sendable {
  public let shape: IndicatorShape
  /// `nil` means the indicator stays silent. A toast fires only when the outcome is not already
  /// obvious on screen: inserted text is right there in the person's document, so announcing
  /// "inserted" would nag on the most common path. Silence on success is the design, not an
  /// oversight.
  public let toast: String?
  public let accessibilityDescription: String

  public init(_ state: IndicatorState) {
    switch state {
    case .ready:
      (shape, toast, accessibilityDescription) = (.collapsed, nil, "Poptart ready")
    case .unavailableSecureTarget:
      (shape, toast, accessibilityDescription) = (
        .collapsed, "Not available in a password field", "Dictation unavailable in secure field"
      )
    case .recording(let activity):
      (shape, toast, accessibilityDescription) = (.waveform(level: activity), nil, "Recording")
    case .approachingRecordingLimit(let activity):
      (shape, toast, accessibilityDescription) = (
        .waveform(level: activity), "Thirty seconds left", "Recording limit approaching"
      )
    case .finalizingRecognition:
      (shape, toast, accessibilityDescription) = (.spinner, nil, "Finalizing recognition")
    case .cleaning:
      (shape, toast, accessibilityDescription) = (.spinner, nil, "Cleaning dictation")
    case .delivering:
      (shape, toast, accessibilityDescription) = (.spinner, nil, "Delivering dictation")
    case .success:
      (shape, toast, accessibilityDescription) = (.collapsed, nil, "Dictation inserted")
    case .rawTranscriptFallback:
      (shape, toast, accessibilityDescription) = (.collapsed, nil, "Raw transcript inserted")
    case .oversizedFallback:
      (shape, toast, accessibilityDescription) = (
        .collapsed, nil, "Deterministic cleanup inserted"
      )
    case .recognitionFallback:
      (shape, toast, accessibilityDescription) = (
        .collapsed, nil, "Recognition hypothesis inserted"
      )
    case .copiedBecauseTargetChanged:
      (shape, toast, accessibilityDescription) = (
        .collapsed, "Copied to clipboard", "Target changed; dictation copied"
      )
    case .copiedBecauseNoTarget:
      (shape, toast, accessibilityDescription) = (
        .collapsed, "Copied to clipboard", "No text field; dictation copied"
      )
    case .failure:
      (shape, toast, accessibilityDescription) = (
        .collapsed, "Dictation failed", "Dictation failed"
      )
    case .cancelled:
      (shape, toast, accessibilityDescription) = (.collapsed, nil, "Dictation cancelled")
    }
  }
}
