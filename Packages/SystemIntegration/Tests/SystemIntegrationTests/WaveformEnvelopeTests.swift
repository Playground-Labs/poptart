import DictationCore
import Testing

@testable import SystemIntegration

@Suite("Waveform envelope")
struct WaveformEnvelopeTests {
  @Test("random heights stay silent without microphone energy")
  func silenceStaysStill() {
    var envelope = WaveformEnvelope()
    for _ in 0..<20 { envelope.advance(overall: 0, randomWeight: { 1 }) }
    #expect(envelope.levels == Array(repeating: 0, count: AudioLevels.bandCount))
  }

  @Test("bars vary independently without mirroring or frequency input")
  func independentHeights() {
    var envelope = WaveformEnvelope()
    var index = 0
    envelope.advance(overall: 0.1) {
      index += 1
      return Double(index) / Double(AudioLevels.bandCount)
    }
    #expect(envelope.levels.count == AudioLevels.bandCount)
    #expect(Set(envelope.levels).count == AudioLevels.bandCount)
    #expect(envelope.levels != Array(envelope.levels.reversed()))
    #expect(envelope.levels.allSatisfy { (0...1).contains($0) })
  }

  @Test("random targets refresh every four frames and ease between heights")
  func refreshAndSmooth() {
    var envelope = WaveformEnvelope()
    var calls = 0
    for _ in 0..<4 {
      envelope.advance(overall: 1) {
        calls += 1
        return 0.2
      }
    }
    #expect(calls == AudioLevels.bandCount)
    let previous = envelope.levels[0]
    envelope.advance(overall: 1, randomWeight: { 1 })
    #expect(envelope.levels[0] > previous)
    #expect(envelope.levels[0] < 1)
  }

  @Test("louder speech raises the waveform and silence lets it decay")
  func followsMicrophoneEnergy() {
    var quiet = WaveformEnvelope()
    var loud = WaveformEnvelope()
    quiet.advance(overall: 0.01, randomWeight: { 1 })
    loud.advance(overall: 0.1, randomWeight: { 1 })
    #expect(loud.levels[0] > quiet.levels[0])
    let peak = loud.levels[0]
    loud.advance(overall: 0, randomWeight: { 1 })
    #expect(loud.levels[0] > 0)
    #expect(loud.levels[0] < peak)
    for _ in 0..<60 { loud.advance(overall: 0, randomWeight: { 1 }) }
    #expect(loud.levels.allSatisfy { $0 < 0.001 })
  }

  @Test("reset clears the previous recording and requests fresh heights")
  func resets() {
    var envelope = WaveformEnvelope()
    envelope.advance(overall: 0.1, randomWeight: { 1 })
    envelope.reset()
    #expect(envelope.levels == Array(repeating: 0, count: AudioLevels.bandCount))
    envelope.advance(overall: 0.1, randomWeight: { 0 })
    #expect(envelope.levels.allSatisfy { $0 == 0 })
  }
}
