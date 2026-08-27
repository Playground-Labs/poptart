import DictationCore
import Foundation
import XCTest
@testable import Recognition

final class FluidAudioIncrementalRecognizerTests: XCTestCase {
    func testFinalizationFailureFallsBackToTheHypothesisWithoutWaitingOutTheDeadline() async {
        let clock = CountingFixedClock()
        let latestHypothesis = LatestHypothesisStore()
        latestHypothesis.replace(with: "Latest usable words")
        let recognizer = makeRecognizer(clock: clock, latestHypothesis: latestHypothesis)

        // An unprepared streaming manager fails finalization immediately, well
        // inside the deadline.
        let finalization = await recognizer.finish(deadline: .init(nanoseconds: 1_000_000_000))

        XCTAssertEqual(finalization, .deadlineFallback("Latest usable words"))
        // The deadline is read once, to size the race. A second reading means the
        // recognizer went back to burn the rest of the budget it no longer needs.
        XCTAssertEqual(clock.readings, 1)
    }

    func testFinalizationFailureWithoutAHypothesisReportsTheTypedFailure() async {
        let clock = CountingFixedClock()
        let recognizer = makeRecognizer(clock: clock, latestHypothesis: LatestHypothesisStore())

        let finalization = await recognizer.finish(deadline: .init(nanoseconds: 1_000_000_000))

        XCTAssertEqual(finalization, .failed(.finalizationFailed))
        XCTAssertEqual(clock.readings, 1)
    }

    private func makeRecognizer(
        clock: any MonotonicClock,
        latestHypothesis: LatestHypothesisStore
    ) -> FluidAudioIncrementalRecognizer {
        FluidAudioIncrementalRecognizer(
            modelLayout: .init(
                unifiedModelDirectory: FileManager.default.temporaryDirectory
                    .appendingPathComponent(UUID().uuidString, isDirectory: true)
            ),
            clock: clock,
            latestHypothesis: latestHypothesis
        )
    }
}

/// A clock stopped at the start of the recognition budget that counts how often
/// the recognizer consults it.
private final class CountingFixedClock: MonotonicClock, @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var readings: Int { lock.withLock { count } }

    func now() -> MonotonicInstant {
        lock.withLock {
            count += 1
            return .zero
        }
    }
}
