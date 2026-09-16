import DictationCore
import Testing

@testable import SystemIntegration

@Suite("Waveform envelope")
struct WaveformEnvelopeTests {
  @Test("a new envelope rests at silence")
  func startsSilent() {
    #expect(WaveformEnvelope().levels == Array(repeating: 0, count: AudioLevels.bandCount))
  }

  @Test("a bar rises faster than it falls")
  func risesFastAndFallsSlow() {
    let full = Array(repeating: 1.0, count: AudioLevels.bandCount)
    var rising = WaveformEnvelope()
    rising.advance(toward: full)
    let gained = rising.levels[0]

    var falling = WaveformEnvelope()
    for _ in 0..<40 { falling.advance(toward: full) }
    let beforeFall = falling.levels[0]
    falling.advance(toward: Array(repeating: 0.0, count: AudioLevels.bandCount))
    let lost = beforeFall - falling.levels[0]

    #expect(gained > lost)
  }

  @Test("a step up never overshoots the level the microphone reported")
  func neverExceedsItsInput() {
    var envelope = WaveformEnvelope()
    let target = Array(repeating: 0.4, count: AudioLevels.bandCount)
    for _ in 0..<100 {
      envelope.advance(toward: target)
      #expect(envelope.levels.allSatisfy { $0 <= 0.4 })
    }
  }

  @Test("a held level converges on itself")
  func convergesOnAHeldLevel() {
    var envelope = WaveformEnvelope()
    let target = Array(repeating: 0.7, count: AudioLevels.bandCount)
    for _ in 0..<200 { envelope.advance(toward: target) }
    #expect(envelope.levels.allSatisfy { abs($0 - 0.7) < 0.001 })

    for _ in 0..<400 {
      envelope.advance(toward: Array(repeating: 0.0, count: AudioLevels.bandCount))
    }
    #expect(envelope.levels.allSatisfy { $0 < 0.001 })
  }

  @Test("each band follows its own band and no other")
  func bandsAreIndependent() {
    var envelope = WaveformEnvelope()
    var target = Array(repeating: 0.0, count: AudioLevels.bandCount)
    target[3] = 1
    for _ in 0..<20 { envelope.advance(toward: target) }
    #expect(envelope.levels[3] > 0.9)
    #expect(envelope.levels.enumerated().allSatisfy { $0.offset == 3 || $0.element == 0 })
  }

  @Test("a reset drops the tail of the last recording")
  func resetReturnsToSilence() {
    var envelope = WaveformEnvelope()
    envelope.advance(toward: Array(repeating: 1.0, count: AudioLevels.bandCount))
    envelope.reset()
    #expect(envelope.levels == Array(repeating: 0, count: AudioLevels.bandCount))
  }

  @Test("a target of the wrong width is ignored rather than crashing the Indicator")
  func ignoresAMismatchedTarget() {
    var envelope = WaveformEnvelope()
    envelope.advance(toward: [1, 1, 1])
    #expect(envelope.levels == Array(repeating: 0, count: AudioLevels.bandCount))
  }
}
