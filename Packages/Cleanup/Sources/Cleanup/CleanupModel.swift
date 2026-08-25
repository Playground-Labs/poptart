import DictationCore
import Foundation

public struct CleanupModelRequest: Equatable, Sendable {
  public let systemInstruction: String
  public let prompt: String
  public let enableThinking: Bool
  public let maximumOutputTokens: Int
  public let stopMarker: String

  public init(
    systemInstruction: String,
    prompt: String,
    enableThinking: Bool,
    maximumOutputTokens: Int,
    stopMarker: String
  ) {
    self.systemInstruction = systemInstruction
    self.prompt = prompt
    self.enableThinking = enableThinking
    self.maximumOutputTokens = maximumOutputTokens
    self.stopMarker = stopMarker
  }
}

public protocol CleanupModelBoundary: Sendable {
  func tokenCount(for request: CleanupModelRequest) async throws(CleanupModelError) -> Int
  func generate(_ request: CleanupModelRequest) async throws(CleanupModelError) -> AsyncStream<
    String
  >
}

public enum CleanupModelError: Error, Equatable, Sendable {
  case unavailable
  case invalidLocalDirectory
  case generationFailed
}

public enum CleanupDeadlineWaitResult: Sendable {
  case reached
  case cancelled
}

public protocol CleanupDeadlineWaiting: Sendable {
  func wait(until deadline: MonotonicInstant) async -> CleanupDeadlineWaitResult
}

public struct SystemCleanupDeadlineWaiter: CleanupDeadlineWaiting {
  private let clock: any MonotonicClock

  public init(clock: any MonotonicClock) {
    self.clock = clock
  }

  public func wait(until deadline: MonotonicInstant) async -> CleanupDeadlineWaitResult {
    let remaining = max(0, deadline.nanoseconds - clock.now().nanoseconds)
    do {
      try await Task.sleep(for: .nanoseconds(remaining))
      return .reached
    } catch {
      return .cancelled
    }
  }
}

public struct CleanupConfiguration: Equatable, Sendable {
  public let maximumInputTokens: Int
  public let maximumOutputTokens: Int
  public let maximumPlanBytes: Int
  public let maximumEdits: Int
  public let maximumChangedProportion: Double
  public let maximumReplacementCharacters: Int

  public init(
    maximumInputTokens: Int,
    maximumOutputTokens: Int = 128,
    maximumPlanBytes: Int = 8_192,
    maximumEdits: Int = 8,
    maximumChangedProportion: Double = 0.35,
    maximumReplacementCharacters: Int = 64
  ) {
    precondition(maximumInputTokens > 0)
    precondition(maximumOutputTokens > 0)
    precondition(maximumPlanBytes > 0)
    precondition(maximumEdits > 0)
    precondition(maximumChangedProportion > 0 && maximumChangedProportion <= 1)
    precondition(maximumReplacementCharacters > 0)
    self.maximumInputTokens = maximumInputTokens
    self.maximumOutputTokens = maximumOutputTokens
    self.maximumPlanBytes = maximumPlanBytes
    self.maximumEdits = maximumEdits
    self.maximumChangedProportion = maximumChangedProportion
    self.maximumReplacementCharacters = maximumReplacementCharacters
  }
}
