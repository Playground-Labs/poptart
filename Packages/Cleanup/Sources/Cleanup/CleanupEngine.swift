import DictationCore
import Foundation

public actor CleanupEngine: CleanupBoundary {
  private let model: any CleanupModelBoundary
  private let deadlineWaiter: any CleanupDeadlineWaiting
  private let configuration: CleanupConfiguration
  private var active: [DictationID: ActiveInvocation] = [:]

  public init(
    model: any CleanupModelBoundary,
    deadlineWaiter: any CleanupDeadlineWaiting,
    configuration: CleanupConfiguration
  ) {
    self.model = model
    self.deadlineWaiter = deadlineWaiter
    self.configuration = configuration
  }

  public func clean(_ request: CleanupRequest) async -> CleanupResult {
    let transcript = StableTranscript(request.rawTranscript.text)
    let deterministic = ExplicitCorrections.edits(in: transcript)
    guard
      let prompt = try? CleanupPrompt.build(
        transcript: transcript,
        targetContext: request.targetContext,
        personalVocabulary: request.personalVocabulary,
        reservedEdits: deterministic
      )
    else { return .rawTranscriptFallback(.cleanupFailed) }
    let modelRequest = CleanupModelRequest(
      systemInstruction: CleanupPrompt.cleanupSystemInstruction,
      prompt: prompt,
      enableThinking: false,
      maximumOutputTokens: configuration.maximumOutputTokens,
      stopMarker: CleanupPrompt.stopMarker
    )
    let channel = FirstCleanupOutcome()
    let model = self.model
    let configuration = self.configuration
    let modelTask = Task.detached {
      let outcome = await Self.performModelWork(
        model: model,
        modelRequest: modelRequest,
        transcript: transcript,
        deterministic: deterministic,
        request: request,
        configuration: configuration
      )
      await channel.resolve(outcome)
    }
    let waiter = deadlineWaiter
    let deadlineTask = Task.detached {
      if await waiter.wait(until: request.deadline) == .reached {
        await channel.resolve(.fallback(.cleanupTimedOut))
      }
    }
    active[request.id] = .init(model: modelTask, deadline: deadlineTask, channel: channel)

    let outcome = await withTaskCancellationHandler {
      await channel.value()
    } onCancel: {
      modelTask.cancel()
      deadlineTask.cancel()
      Task { await channel.resolve(.fallback(.cleanupTimedOut)) }
    }
    active.removeValue(forKey: request.id)
    modelTask.cancel()
    deadlineTask.cancel()
    return outcome.result
  }

  public func cancelCleanup(for id: DictationID) async {
    guard let invocation = active[id] else { return }
    invocation.model.cancel()
    invocation.deadline.cancel()
    await invocation.channel.resolve(.fallback(.cleanupTimedOut))
  }

  private nonisolated static func performModelWork(
    model: any CleanupModelBoundary,
    modelRequest: CleanupModelRequest,
    transcript: StableTranscript,
    deterministic: [CleanupEdit],
    request: CleanupRequest,
    configuration: CleanupConfiguration
  ) async -> ModelWorkOutcome {
    do {
      let tokenCount = try await model.tokenCount(for: modelRequest)
      if tokenCount > configuration.maximumInputTokens {
        let text = CleanupEditApplier.apply(deterministic, to: transcript)
        return .oversized(
          .init(
            text: text,
            metadata: .init(changed: text != transcript.source, editCount: deterministic.count)
          ))
      }

      let stream = try await model.generate(modelRequest)
      var parser = BoundedEditPlanParser(maximumBytes: configuration.maximumPlanBytes)
      var plan: CleanupEditPlan?
      for await chunk in stream {
        try Task.checkCancellation()
        if plan != nil {
          guard chunk.isEmpty else { throw CleanupEditPlanError.malformed }
        } else if let parsed = try parser.append(chunk) {
          plan = parsed
        }
      }
      guard let plan else { throw CleanupEditPlanError.incomplete }
      let edits = try CleanupEditPlanValidator(configuration: configuration).validate(
        plan,
        transcript: transcript,
        reservedEdits: deterministic,
        targetContext: request.targetContext,
        personalVocabulary: request.personalVocabulary
      )
      let text = CleanupEditApplier.apply(edits, to: transcript)
      return .cleaned(
        .init(
          text: text,
          metadata: .init(changed: text != transcript.source, editCount: edits.count)
        ))
    } catch let error as CleanupModelError {
      switch error {
      case .unavailable, .invalidLocalDirectory:
        return .fallback(.modelUnavailable)
      case .generationFailed:
        return .fallback(.cleanupFailed)
      }
    } catch is CancellationError {
      return .fallback(.cleanupTimedOut)
    } catch is CleanupEditPlanError {
      return .fallback(.unsafeEditPlan)
    } catch is CleanupEditValidationError {
      return .fallback(.unsafeEditPlan)
    } catch {
      return .fallback(.cleanupFailed)
    }
  }
}

private struct ActiveInvocation: Sendable {
  let model: Task<Void, Never>
  let deadline: Task<Void, Never>
  let channel: FirstCleanupOutcome
}

private enum ModelWorkOutcome: Sendable {
  case cleaned(CleanupOutput)
  case oversized(CleanupOutput)
  case fallback(RawTranscriptFallbackReason)

  var result: CleanupResult {
    switch self {
    case .cleaned(let output): .cleaned(output)
    case .oversized(let output): .oversizedDeterministic(output)
    case .fallback(let reason): .rawTranscriptFallback(reason)
    }
  }
}

private actor FirstCleanupOutcome {
  private var outcome: ModelWorkOutcome?
  private var continuation: CheckedContinuation<ModelWorkOutcome, Never>?

  func value() async -> ModelWorkOutcome {
    if let outcome { return outcome }
    return await withCheckedContinuation { continuation = $0 }
  }

  func resolve(_ newOutcome: ModelWorkOutcome) {
    guard outcome == nil else { return }
    outcome = newOutcome
    continuation?.resume(returning: newOutcome)
    continuation = nil
  }
}
