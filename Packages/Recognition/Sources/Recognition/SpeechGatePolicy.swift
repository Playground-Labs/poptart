import Foundation

/// A voice activity verdict for one fixed-length span of captured audio.
enum SpeechGateDecision: Equatable, Sendable {
    case speech
    case nonSpeech
}

/// What the gate does with the oldest chunk it is still holding.
enum SpeechGateRelease: Equatable, Sendable {
    /// Forward the chunk to the recognizer unchanged.
    case pass
    /// Forward the chunk as digital silence. Non-speech is zeroed rather than dropped: dropping
    /// splices unrelated speech together and disturbs the streaming recognizer's continuity, while
    /// clean silence is what the recognizer most reliably transcribes as nothing.
    case silence
}

/// Decides, from a sequence of per-chunk voice activity verdicts, which chunks of captured audio
/// reach the recognizer intact and which are replaced by silence.
///
/// Pure, so the property that actually matters — the first syllable of a dictation survives — is
/// provable without a model, a microphone or a recognizer.
struct SpeechGatePolicy: Equatable, Sendable {
    /// Chunks withheld so a chunk can still be released intact once the *next* chunk turns out to
    /// be speech. A detector only calls a chunk speech when enough of the chunk is speech, so the
    /// chunk carrying a word's onset is routinely scored as non-speech. Without this hold the
    /// beginning of the first word is zeroed, which is unacceptable for dictation.
    static let preRollChunks = 1

    /// Chunks of non-speech still forwarded intact after speech stops. Pauses between words and
    /// while thinking routinely outlast a single chunk; closing the gate on the first quiet chunk
    /// would punch holes into the middle of an utterance and clip its tail.
    static let hangoverChunks = 2

    private var heldChunks = 0
    private var hangoverRemaining = 0

    init() {}

    /// Records the verdict for the newest chunk and returns what to do with the chunks the gate
    /// holds, oldest first.
    mutating func admit(_ decision: SpeechGateDecision) -> [SpeechGateRelease] {
        heldChunks += 1
        switch decision {
        case .speech:
            hangoverRemaining = Self.hangoverChunks
            return releaseEverythingHeld(as: .pass)
        case .nonSpeech where hangoverRemaining > 0:
            hangoverRemaining -= 1
            return releaseEverythingHeld(as: .pass)
        case .nonSpeech:
            var releases: [SpeechGateRelease] = []
            while heldChunks > Self.preRollChunks {
                heldChunks -= 1
                releases.append(.silence)
            }
            return releases
        }
    }

    /// Releases the pre-roll when capture ends, so no chunk is ever silently dropped. Anything
    /// still held at this point was scored non-speech with the hangover already spent — every
    /// other path empties the hold as it releases.
    mutating func flush() -> [SpeechGateRelease] {
        releaseEverythingHeld(as: .silence)
    }

    private mutating func releaseEverythingHeld(
        as release: SpeechGateRelease
    ) -> [SpeechGateRelease] {
        let releases = Array(repeating: release, count: heldChunks)
        heldChunks = 0
        return releases
    }
}
