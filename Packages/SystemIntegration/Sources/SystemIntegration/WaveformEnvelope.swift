import DictationCore

/// Holds the level each waveform bar is currently drawn at, and walks it toward what the
/// microphone last reported.
///
/// Measured bands jump between one buffer and the next, and drawing them raw makes the bars strobe
/// rather than move. A meter rises almost as fast as the sound arriving and falls slowly, which is
/// what lets an eye read a syllable: the rise is the event, the fall is the trail that makes the
/// rise legible.
struct WaveformEnvelope {
  private(set) var levels: [Double]
  private let attack: Double
  private let release: Double

  init(
    bandCount: Int = AudioLevels.bandCount,
    attack: Double = 0.55,
    release: Double = 0.12
  ) {
    precondition(bandCount > 0)
    precondition(attack > 0 && attack <= 1)
    precondition(release > 0 && release <= 1)
    levels = Array(repeating: 0, count: bandCount)
    self.attack = attack
    self.release = release
  }

  /// Moves every bar one frame's worth toward `target`. A bar never passes its target, so a step up
  /// cannot overshoot into a level the microphone never heard.
  mutating func advance(toward target: [Double]) {
    guard target.count == levels.count else { return }
    for index in levels.indices {
      let destination = target[index]
      let rate = destination > levels[index] ? attack : release
      levels[index] += (destination - levels[index]) * rate
    }
  }

  /// Drops every bar back to silence, so a new recording does not open on the last one's tail.
  mutating func reset() {
    levels = Array(repeating: 0, count: levels.count)
  }
}
