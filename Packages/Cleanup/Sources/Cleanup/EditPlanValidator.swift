import DictationCore
import Foundation

public enum CleanupEditValidationError: Error, Equatable, Sendable {
  case tooManyEdits
  case invalidBounds
  case unorderedOrOverlapping
  case reservedSpan
  case unsafeUnicode
  case replacementTooLarge
  case excessiveChange
  case copiedTargetContext
  case unsafeCategory
  case blankOutput
}

public struct CleanupEditPlanValidator: Sendable {
  private let configuration: CleanupConfiguration

  public init(configuration: CleanupConfiguration) {
    self.configuration = configuration
  }

  public func validate(
    _ plan: CleanupEditPlan,
    transcript: StableTranscript,
    reservedEdits: [CleanupEdit],
    targetContext: TargetContext,
    personalVocabulary: PersonalVocabulary
  ) throws -> [CleanupEdit] {
    guard plan.edits.count <= configuration.maximumEdits else {
      throw CleanupEditValidationError.tooManyEdits
    }

    var previousEnd = 0
    var previousWasInsertion = false
    var changedCharacters = 0
    for (position, edit) in plan.edits.enumerated() {
      guard edit.startSpan >= 0,
        edit.endSpan >= edit.startSpan,
        edit.endSpan <= transcript.spans.count
      else { throw CleanupEditValidationError.invalidBounds }

      let isInsertion = edit.startSpan == edit.endSpan
      if position > 0,
        edit.startSpan < previousEnd
          || (isInsertion && previousWasInsertion && edit.startSpan == previousEnd)
      {
        throw CleanupEditValidationError.unorderedOrOverlapping
      }
      previousEnd = edit.endSpan
      previousWasInsertion = isInsertion

      guard !reservedEdits.contains(where: { conflicts(edit, with: $0) }) else {
        throw CleanupEditValidationError.reservedSpan
      }
      guard edit.replacement.count <= configuration.maximumReplacementCharacters else {
        throw CleanupEditValidationError.replacementTooLarge
      }
      guard edit.replacement.unicodeScalars.allSatisfy(isSafe) else {
        throw CleanupEditValidationError.unsafeUnicode
      }

      let source = sourceText(for: edit, in: transcript)
      guard source != edit.replacement else {
        throw CleanupEditValidationError.unsafeCategory
      }
      guard
        !copiesContext(
          edit.replacement,
          rawTranscript: transcript.source,
          targetContext: targetContext,
          personalVocabulary: personalVocabulary
        )
      else { throw CleanupEditValidationError.copiedTargetContext }
      guard
        isCategorySafe(
          edit,
          source: source,
          transcript: transcript,
          personalVocabulary: personalVocabulary
        )
      else { throw CleanupEditValidationError.unsafeCategory }

      changedCharacters += max(source.count, edit.replacement.count)
    }

    let allowedChanges = max(
      8,
      Int(ceil(Double(transcript.source.count) * configuration.maximumChangedProportion))
    )
    guard changedCharacters <= allowedChanges else {
      throw CleanupEditValidationError.excessiveChange
    }

    let merged = (reservedEdits + plan.edits).sorted(by: CleanupEditApplier.editOrder)
    let output = CleanupEditApplier.apply(merged, to: transcript)
    if output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      guard removesOnlyFiller(merged, transcript: transcript) else {
        throw CleanupEditValidationError.blankOutput
      }
    }
    return merged
  }

  /// A blank result is allowed only when the Raw Transcript contained only removable filler, so
  /// every applied edit must have deleted filler, or the punctuation attached to it, under the
  /// same category checks each edit already passed. Repetition and every other category can carry
  /// substantive wording, so they can never empty the result.
  ///
  /// The `.filler` category check reads a span through a word list that ignores symbols, so a span
  /// of "um 😀 uh" looks like pure filler to it. Emptying the whole Dictation destroys anything it
  /// overlooked, so the deleted spans are rechecked here: everything outside the filler words must
  /// be punctuation or whitespace.
  private func removesOnlyFiller(_ edits: [CleanupEdit], transcript: StableTranscript) -> Bool {
    edits.contains { $0.category == .filler }
      && edits.allSatisfy { edit in
        edit.replacement.isEmpty
          && (edit.category == .filler || edit.category == .punctuation)
          && transcript.spans[edit.startSpan..<edit.endSpan].allSatisfy { span in
            Self.fillerWords.contains(span.text.lowercased())
              || span.text.unicodeScalars.allSatisfy { Self.isPunctuationOrWhitespace($0) }
          }
      }
  }

  private static let fillerWords: Set<String> = ["ah", "er", "erm", "hmm", "like", "uh", "um"]

  private static func isPunctuationOrWhitespace(_ scalar: Unicode.Scalar) -> Bool {
    CharacterSet.punctuationCharacters.contains(scalar)
      || CharacterSet.whitespacesAndNewlines.contains(scalar)
  }

  private func conflicts(_ model: CleanupEdit, with reserved: CleanupEdit) -> Bool {
    if model.startSpan == model.endSpan {
      return model.startSpan > reserved.startSpan && model.startSpan < reserved.endSpan
    }
    return model.startSpan < reserved.endSpan && reserved.startSpan < model.endSpan
  }

  private func sourceText(for edit: CleanupEdit, in transcript: StableTranscript) -> String {
    guard edit.startSpan < edit.endSpan else { return "" }
    let lower = String.Index(
      utf16Offset: transcript.spans[edit.startSpan].utf16Range.lowerBound,
      in: transcript.source
    )
    let upper = String.Index(
      utf16Offset: transcript.spans[edit.endSpan - 1].utf16Range.upperBound,
      in: transcript.source
    )
    return String(transcript.source[lower..<upper])
  }

  private func isSafe(_ scalar: Unicode.Scalar) -> Bool {
    switch scalar.properties.generalCategory {
    case .control, .format, .lineSeparator, .paragraphSeparator, .surrogate, .privateUse,
      .unassigned:
      return false
    default:
      return true
    }
  }

  private func copiesContext(
    _ replacement: String,
    rawTranscript: String,
    targetContext: TargetContext,
    personalVocabulary: PersonalVocabulary
  ) -> Bool {
    let contextWords = words(
      targetContext.textBeforeCursor + " " + targetContext.textAfterCursor + " "
        + (targetContext.selectedText ?? "")
    )
    let rawWords = words(rawTranscript)
    let vocabularyWords = Set(personalVocabulary.entries.flatMap(words))
    return words(replacement).contains {
      $0.count >= 4 && contextWords.contains($0) && !rawWords.contains($0)
        && !vocabularyWords.contains($0)
    }
  }

  private func isCategorySafe(
    _ edit: CleanupEdit,
    source: String,
    transcript: StableTranscript,
    personalVocabulary: PersonalVocabulary
  ) -> Bool {
    switch edit.category {
    case .punctuation:
      return edit.replacement.unicodeScalars.allSatisfy {
        CharacterSet.punctuationCharacters.contains($0)
          || CharacterSet.whitespacesAndNewlines.contains($0)
      }
        && source.unicodeScalars.allSatisfy {
          CharacterSet.punctuationCharacters.contains($0)
            || CharacterSet.whitespacesAndNewlines.contains($0)
        }
    case .capitalization:
      return !source.isEmpty && source.lowercased() == edit.replacement.lowercased()
    case .filler:
      let sourceWords = words(source)
      return edit.replacement.isEmpty && !sourceWords.isEmpty
        && sourceWords.isSubset(of: Self.fillerWords)
    case .repetition:
      guard edit.replacement.isEmpty,
        edit.startSpan < edit.endSpan,
        wordList(source).count == 1,
        let first = wordList(source).first
      else { return false }
      let before = edit.startSpan > 0 ? transcript.spans[edit.startSpan - 1].text.lowercased() : nil
      let after =
        edit.endSpan < transcript.spans.count
        ? transcript.spans[edit.endSpan].text.lowercased()
        : nil
      return first == before || first == after
    case .correction:
      // Authoritative Explicit Corrections are reserved by deterministic code.
      // A model-authored correction would bypass the unmistakability check.
      return false
    case .vocabulary:
      return !source.isEmpty
        && personalVocabulary.entries.contains(edit.replacement)
        && normalizedVocabularyText(source) == normalizedVocabularyText(edit.replacement)
    }
  }

  private func words(_ text: String) -> Set<String> {
    Set(wordList(text))
  }

  private func wordList(_ text: String) -> [String] {
    StableTranscript(text).spans.compactMap { span in
      span.text.unicodeScalars.contains(where: CharacterSet.alphanumerics.contains)
        ? span.text.lowercased()
        : nil
    }
  }

  private func normalizedVocabularyText(_ text: String) -> String {
    String(text.lowercased().unicodeScalars.filter(CharacterSet.alphanumerics.contains))
  }

}

public enum CleanupEditApplier {
  public static func apply(_ edits: [CleanupEdit], to transcript: StableTranscript) -> String {
    guard !edits.isEmpty else { return transcript.source }
    var output = ""
    var cursor = transcript.source.startIndex

    for edit in edits {
      let offsets = sourceOffsets(for: edit, in: transcript)
      guard let offsets else { return transcript.source }
      var lower = String.Index(utf16Offset: offsets.lowerBound, in: transcript.source)
      var upper = String.Index(utf16Offset: offsets.upperBound, in: transcript.source)

      if edit.replacement.isEmpty, lower < upper {
        if edit.endSpan < transcript.spans.count {
          let next = String.Index(
            utf16Offset: transcript.spans[edit.endSpan].utf16Range.lowerBound,
            in: transcript.source
          )
          if transcript.source[upper..<next].allSatisfy(\.isWhitespace) { upper = next }
        } else if lower > cursor {
          let prior = transcript.source[cursor..<lower]
          if let lastNonWhitespace = prior.lastIndex(where: { !$0.isWhitespace }) {
            lower = transcript.source.index(after: lastNonWhitespace)
          }
        }
      }

      guard lower >= cursor else { return transcript.source }
      output += transcript.source[cursor..<lower]
      output += edit.replacement
      cursor = upper
    }
    output += transcript.source[cursor...]
    return output
  }

  static func editOrder(_ lhs: CleanupEdit, _ rhs: CleanupEdit) -> Bool {
    if lhs.startSpan == rhs.startSpan { return lhs.endSpan < rhs.endSpan }
    return lhs.startSpan < rhs.startSpan
  }

  private static func sourceOffsets(
    for edit: CleanupEdit,
    in transcript: StableTranscript
  ) -> Range<Int>? {
    guard edit.startSpan >= 0,
      edit.endSpan >= edit.startSpan,
      edit.endSpan <= transcript.spans.count
    else { return nil }
    if edit.startSpan == edit.endSpan {
      let offset =
        edit.startSpan == transcript.spans.count
        ? transcript.source.utf16.count
        : transcript.spans[edit.startSpan].utf16Range.lowerBound
      return offset..<offset
    }
    return transcript.spans[edit.startSpan].utf16Range
      .lowerBound..<transcript.spans[edit.endSpan - 1].utf16Range.upperBound
  }
}
