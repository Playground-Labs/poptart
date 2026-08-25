import Foundation

enum ExplicitCorrections {
  static func edits(in transcript: StableTranscript) -> [CleanupEdit] {
    let spans = transcript.spans
    guard spans.count >= 4 else { return [] }
    var result: [CleanupEdit] = []

    for index in 1..<(spans.count - 2)
    where spans[index].text.caseInsensitiveCompare("I") == .orderedSame {
      guard spans[index + 1].text.caseInsensitiveCompare("mean") == .orderedSame,
        let abandoned = previousWord(before: index, spans: spans),
        let correction = nextWord(after: index + 1, spans: spans),
        abandoned < index,
        correction > index + 1,
        spans[(abandoned + 1)..<index].contains(where: isCorrectionSeparator),
        spans[(abandoned + 1)..<index].allSatisfy(isCorrectionSeparator),
        spans[(index + 2)..<correction].allSatisfy(isCorrectionSeparator)
      else { continue }

      let edit = CleanupEdit(
        startSpan: abandoned,
        endSpan: correction + 1,
        replacement: spans[correction].text,
        category: .correction
      )
      guard result.last.map({ $0.endSpan <= edit.startSpan }) ?? true else { continue }
      result.append(edit)
    }
    return result
  }

  private static func previousWord(before index: Int, spans: [TranscriptSpan]) -> Int? {
    spans[..<index].lastIndex {
      $0.text.unicodeScalars.contains { CharacterSet.alphanumerics.contains($0) }
    }
  }

  private static func nextWord(after index: Int, spans: [TranscriptSpan]) -> Int? {
    spans.indices.dropFirst(index + 1).first {
      spans[$0].text.unicodeScalars.contains { CharacterSet.alphanumerics.contains($0) }
    }
  }

  private static func isCorrectionSeparator(_ span: TranscriptSpan) -> Bool {
    span.text.unicodeScalars.allSatisfy(CharacterSet.punctuationCharacters.contains)
  }
}
