import DictationCore
import Foundation

/// Smooth, decorative bars driven by microphone loudness, not individual frequencies.
struct WaveformEnvelope {
  private(set) var levels = Array(repeating: 0.0, count: AudioLevels.bandCount)
  private var weights = Array(repeating: 0.0, count: AudioLevels.bandCount)
  private var framesUntilRefresh = 0

  /// Pick new independent heights every four display frames, then ease toward them.
  /// Multiplying by microphone energy keeps silence still and speech in control.
  mutating func advance(
    overall: Double,
    randomWeight: () -> Double = { Double.random(in: 0.12...1) }
  ) {
    if framesUntilRefresh == 0 {
      weights = weights.map { _ in randomWeight() }
      framesUntilRefresh = 4
    }
    framesUntilRefresh -= 1
    let energy = 1 - exp(-32 * min(1, max(0, overall)))
    for index in levels.indices {
      let target = energy * weights[index]
      let rate = target > levels[index] ? 0.75 : 0.20
      levels[index] += (target - levels[index]) * rate
    }
  }

  mutating func reset() {
    levels = Array(repeating: 0, count: levels.count)
    framesUntilRefresh = 0
  }
}
