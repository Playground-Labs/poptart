import Foundation

public struct TranscriptSpan: Equatable, Sendable {
  public let index: Int
  public let text: String
  public let utf16Range: Range<Int>

  public init(index: Int, text: String, utf16Range: Range<Int>) {
    self.index = index
    self.text = text
    self.utf16Range = utf16Range
  }
}

public struct StableTranscript: Equatable, Sendable {
  public let source: String
  public let spans: [TranscriptSpan]

  public init(_ source: String) {
    self.source = source
    self.spans = Self.tokenize(source)
  }

  private static func tokenize(_ source: String) -> [TranscriptSpan] {
    let characters = Array(source)
    var spans: [TranscriptSpan] = []
    var word = ""
    var wordStart = 0
    var offset = 0

    func appendWord(endingAt end: Int, to result: inout [TranscriptSpan]) {
      guard !word.isEmpty else { return }
      result.append(.init(index: result.count, text: word, utf16Range: wordStart..<end))
    }

    for position in characters.indices {
      let character = characters[position]
      let width = String(character).utf16.count
      let isApostrophe = character == "'" || character == "’"
      let joinsWord =
        isApostrophe
        && !word.isEmpty
        && characters.index(after: position) < characters.endIndex
        && isWordCharacter(characters[characters.index(after: position)])

      if isWordCharacter(character) || joinsWord {
        if word.isEmpty { wordStart = offset }
        word.append(character)
      } else {
        appendWord(endingAt: offset, to: &spans)
        word = ""
        if !character.isWhitespace {
          spans.append(
            .init(
              index: spans.count,
              text: String(character),
              utf16Range: offset..<(offset + width)
            ))
        }
      }
      offset += width
    }
    appendWord(endingAt: offset, to: &spans)
    return spans
  }

  private static func isWordCharacter(_ character: Character) -> Bool {
    character.unicodeScalars.allSatisfy {
      CharacterSet.alphanumerics.contains($0) || CharacterSet.nonBaseCharacters.contains($0)
    }
  }
}
