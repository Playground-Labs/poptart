import AVFoundation
import DictationCore
import Foundation
import XCTest
@testable import Recognition

final class SpeechBandAnalyzerTests: XCTestCase {
    private let frameCount = 1_024
    private let sampleRate = 48_000.0

    func testSilenceProducesNoEnergy() throws {
        let analyzer = try XCTUnwrap(SpeechBandAnalyzer(frameCount: frameCount))
        let levels = analyzer.levels(
            of: [Float](repeating: 0, count: frameCount),
            sampleRate: sampleRate
        )

        XCTAssertEqual(levels.overall, 0, accuracy: 1e-6)
        for band in levels.bands {
            XCTAssertEqual(band, 0, accuracy: 1e-6)
        }
    }

    func testLowToneLightsTheLowBandsAndNotTheHighOnes() throws {
        let analyzer = try XCTUnwrap(SpeechBandAnalyzer(frameCount: frameCount))
        let levels = analyzer.levels(of: tone(at: 120), sampleRate: sampleRate)

        let loudest = try XCTUnwrap(levels.bands.firstIndex(of: levels.bands.max() ?? 0))
        XCTAssertLessThan(loudest, 3)
        XCTAssertGreaterThan(levels.bands[loudest], 0.2)
        for band in levels.bands.suffix(10) {
            XCTAssertLessThan(band, 0.01)
        }
    }

    func testHighToneLightsTheHighBandsAndNotTheLowOnes() throws {
        let analyzer = try XCTUnwrap(SpeechBandAnalyzer(frameCount: frameCount))
        let levels = analyzer.levels(of: tone(at: 6_000), sampleRate: sampleRate)

        let loudest = try XCTUnwrap(levels.bands.firstIndex(of: levels.bands.max() ?? 0))
        XCTAssertGreaterThan(loudest, AudioLevels.bandCount - 4)
        XCTAssertGreaterThan(levels.bands[loudest], 0.2)
        for band in levels.bands.prefix(10) {
            XCTAssertLessThan(band, 0.01)
        }
    }

    func testFullScaleNoiseStaysInsideTheNormalisedRange() throws {
        let analyzer = try XCTUnwrap(SpeechBandAnalyzer(frameCount: frameCount))
        var generator = SystemRandomNumberGenerator()
        let noise = (0..<frameCount).map { _ in Float.random(in: -1...1, using: &generator) }
        let levels = analyzer.levels(of: noise, sampleRate: sampleRate)

        XCTAssertLessThanOrEqual(levels.overall, 1)
        XCTAssertGreaterThan(levels.overall, 0)
        for band in levels.bands {
            XCTAssertLessThanOrEqual(band, 1)
        }
    }

    func testFullScaleToneReachesTheTopOfTheRange() throws {
        let analyzer = try XCTUnwrap(SpeechBandAnalyzer(frameCount: frameCount))
        let levels = analyzer.levels(of: tone(at: 1_500), sampleRate: sampleRate)

        XCTAssertEqual(levels.bands.max() ?? 0, 1, accuracy: 0.15)
    }

    /// A 16 kHz microphone must still fill the top bands, which it cannot if the highest band is
    /// pinned to 8 kHz — its own Nyquist limit.
    func testHighToneStillReachesTheTopBandAtSixteenKilohertz() throws {
        let analyzer = try XCTUnwrap(SpeechBandAnalyzer(frameCount: frameCount))
        let levels = analyzer.levels(
            of: tone(at: 7_000, sampleRate: 16_000),
            sampleRate: 16_000
        )

        let loudest = try XCTUnwrap(levels.bands.firstIndex(of: levels.bands.max() ?? 0))
        XCTAssertGreaterThan(loudest, AudioLevels.bandCount - 4)
    }

    func testOverallLevelIsTheRootMeanSquareOfTheBuffer() throws {
        let analyzer = try XCTUnwrap(SpeechBandAnalyzer(frameCount: frameCount))
        let levels = analyzer.levels(
            of: [Float](repeating: 0.5, count: frameCount),
            sampleRate: sampleRate
        )

        XCTAssertEqual(levels.overall, 0.5, accuracy: 1e-5)
    }

    func testAnalyzerRejectsAFrameCountThatIsNotAPowerOfTwo() {
        XCTAssertNil(SpeechBandAnalyzer(frameCount: 1_000))
    }

    func testOversizedCaptureUsesTheNewestSamples() throws {
        let analyzer = try XCTUnwrap(SpeechBandAnalyzer(frameCount: frameCount))
        let latest = tone(at: 6_000)
        let expected = analyzer.levels(of: latest, sampleRate: sampleRate)
        let actual = analyzer.levels(of: tone(at: 120) + latest, sampleRate: sampleRate)
        XCTAssertEqual(actual.bands, expected.bands)
    }

    func testShortAndEmptyCaptureRemainFinite() throws {
        let analyzer = try XCTUnwrap(SpeechBandAnalyzer(frameCount: frameCount))
        XCTAssertEqual(analyzer.levels(of: [], sampleRate: sampleRate), .silent)
        let levels = analyzer.levels(of: Array(tone(at: 1_500).prefix(240)), sampleRate: sampleRate)
        XCTAssertEqual(levels.bands.count, AudioLevels.bandCount)
        XCTAssertTrue(levels.bands.allSatisfy { $0.isFinite && (0...1).contains($0) })
        XCTAssertGreaterThan(levels.bands.max() ?? 0, 0)
    }

    func testCaptureCopyMeasuresFirstChannelWithoutChangingSamples() throws {
        let analyzer = try XCTUnwrap(SpeechBandAnalyzer(frameCount: frameCount))
        let first = tone(at: 120)
        let second = tone(at: 6_000)
        for interleaved in [false, true] {
            let format = try XCTUnwrap(AVAudioFormat(
                commonFormat: .pcmFormatFloat32, sampleRate: sampleRate,
                channels: 2, interleaved: interleaved
            ))
            let buffer = try XCTUnwrap(AVAudioPCMBuffer(
                pcmFormat: format, frameCapacity: AVAudioFrameCount(frameCount)
            ))
            buffer.frameLength = AVAudioFrameCount(frameCount)
            let channels = try XCTUnwrap(buffer.floatChannelData)
            for index in 0..<frameCount {
                channels[0][index * buffer.stride] = first[index]
                if interleaved {
                    channels[0][index * buffer.stride + 1] = second[index]
                } else {
                    channels[1][index] = second[index]
                }
            }
            let copy = try AVAudioEngineCapture.copy(buffer, analyzer: analyzer)
            XCTAssertEqual(copy.audioActivity, analyzer.levels(of: first, sampleRate: sampleRate))
            let originalBuffers = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)
            let copiedBuffers = UnsafeMutableAudioBufferListPointer(copy.buffer.mutableAudioBufferList)
            for index in originalBuffers.indices {
                XCTAssertEqual(memcmp(
                    try XCTUnwrap(originalBuffers[index].mData),
                    try XCTUnwrap(copiedBuffers[index].mData),
                    Int(originalBuffers[index].mDataByteSize)
                ), 0)
            }
        }
    }

    private func tone(
        at frequency: Double,
        amplitude: Float = 1,
        sampleRate: Double? = nil
    ) -> [Float] {
        let rate = sampleRate ?? self.sampleRate
        return (0..<frameCount).map { index in
            amplitude * Float(sin(2 * Double.pi * frequency * Double(index) / rate))
        }
    }
}
