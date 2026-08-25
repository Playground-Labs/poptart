import Cleanup
import Foundation
import Testing

@Suite("Stable transcript spans")
struct StableTranscriptTests {
  @Test("Span indexes stay ordinal while ranges address the original Unicode text")
  func unicodeStableSpans() {
    let source = "👩🏽‍💻 café CR."
    let transcript = StableTranscript(source)

    #expect(transcript.spans.map(\.index) == Array(transcript.spans.indices))
    #expect(transcript.spans.map(\.text) == ["👩🏽‍💻", "café", "CR", "."])
    for span in transcript.spans {
      let lower = String.Index(utf16Offset: span.utf16Range.lowerBound, in: source)
      let upper = String.Index(utf16Offset: span.utf16Range.upperBound, in: source)
      #expect(String(source[lower..<upper]) == span.text)
    }
  }
}
