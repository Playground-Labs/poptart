import Accelerate
import DictationCore
import Foundation

/// Measures what the microphone is hearing right now: how loud one captured buffer is overall, and
/// how its energy is spread across `AudioLevels.bandCount` bands of the speech range.
///
/// The bands are spaced logarithmically because hearing is: linear spacing would spend most of the
/// Indicator on the top few kilohertz, where a voice has almost nothing to say, and crush every
/// vowel into the first bar.
///
/// Unchecked because `vDSP.FFT` is a class AVFoundation never marked `Sendable`. Its setup is
/// written once in `init` and only read afterwards, so the capture tap can hold one across calls.
struct SpeechBandAnalyzer: @unchecked Sendable {
    /// The lower display boundary; frequencies below it are omitted from the meter.
    static let lowestFrequency = 80.0
    /// The top of the speech range, as an ambition. The real top is clamped against the device's
    /// Nyquist limit so a 16 kHz microphone still fills every band instead of leaving the upper
    /// ones permanently dead.
    static let highestFrequency = 8_000.0

    private let frameCount: Int
    private let fft: vDSP.FFT<DSPSplitComplex>
    private let window: [Float]
    /// Accelerate's real forward transform returns twice the conventional DFT, and a Hann window
    /// passes half the signal through, so a full-scale sine lands at `frameCount / 2`. Dividing by
    /// it puts "as loud as this microphone can go" at exactly 1.
    private let magnitudeScale: Float

    /// Fails when the frame count is not a power of two, which is the only shape the radix-2
    /// transform can take.
    init?(frameCount: Int) {
        guard frameCount >= 4, frameCount.nonzeroBitCount == 1 else { return nil }
        let log2n = vDSP_Length(frameCount.trailingZeroBitCount)
        guard let fft = vDSP.FFT(log2n: log2n, radix: .radix2, ofType: DSPSplitComplex.self) else {
            return nil
        }
        self.frameCount = frameCount
        self.fft = fft
        window = vDSP.window(
            ofType: Float.self,
            usingSequence: .hanningDenormalized,
            count: frameCount,
            isHalfWindow: false
        )
        magnitudeScale = 2 / Float(frameCount)
    }

    func levels(of samples: [Float], sampleRate: Double) -> AudioLevels {
        guard !samples.isEmpty, sampleRate.isFinite, sampleRate > 0 else { return .silent }
        return AudioLevels(
            bands: bands(of: magnitudes(of: samples), sampleRate: sampleRate),
            overall: Double(vDSP.rootMeanSquare(samples))
        )
    }

    /// The magnitude of each positive-frequency bin, scaled so that 1 is full scale.
    private func magnitudes(of samples: [Float]) -> [Float] {
        var padded = [Float](repeating: 0, count: frameCount)
        // Tap sizes are requests, not guarantees. Show the newest frame when capture delivers more.
        padded.replaceSubrange(0..<min(samples.count, frameCount), with: samples.suffix(frameCount))
        let windowed = vDSP.multiply(padded, window)

        let binCount = frameCount / 2
        var inputReal = [Float](repeating: 0, count: binCount)
        var inputImaginary = [Float](repeating: 0, count: binCount)
        var outputReal = [Float](repeating: 0, count: binCount)
        var outputImaginary = [Float](repeating: 0, count: binCount)
        var magnitudes = [Float](repeating: 0, count: binCount)

        inputReal.withUnsafeMutableBufferPointer { inputRealPointer in
            inputImaginary.withUnsafeMutableBufferPointer { inputImaginaryPointer in
                outputReal.withUnsafeMutableBufferPointer { outputRealPointer in
                    outputImaginary.withUnsafeMutableBufferPointer { outputImaginaryPointer in
                        var input = DSPSplitComplex(
                            realp: inputRealPointer.baseAddress!,
                            imagp: inputImaginaryPointer.baseAddress!
                        )
                        var output = DSPSplitComplex(
                            realp: outputRealPointer.baseAddress!,
                            imagp: outputImaginaryPointer.baseAddress!
                        )
                        windowed.withUnsafeBytes { raw in
                            vDSP_ctoz(
                                raw.bindMemory(to: DSPComplex.self).baseAddress!,
                                2,
                                &input,
                                1,
                                vDSP_Length(binCount)
                            )
                        }
                        fft.forward(input: input, output: &output)
                        vDSP_zvabs(&output, 1, &magnitudes, 1, vDSP_Length(binCount))
                    }
                }
            }
        }
        return vDSP.multiply(magnitudeScale, magnitudes)
    }

    /// Folds the bins into log-spaced bands. A band takes the loudest bin it covers rather than
    /// their average, so a narrow tone reads at its real height instead of being diluted by the
    /// silence on either side of it.
    private func bands(of magnitudes: [Float], sampleRate: Double) -> [Double] {
        let binWidth = sampleRate / Double(frameCount)
        let nyquist = sampleRate / 2
        let highest = min(Self.highestFrequency, nyquist * 0.95)
        guard highest > Self.lowestFrequency, binWidth > 0 else {
            return Array(repeating: 0, count: AudioLevels.bandCount)
        }
        let ratio = highest / Self.lowestFrequency
        let lastBin = magnitudes.count - 1
        guard lastBin >= 1 else { return Array(repeating: 0, count: AudioLevels.bandCount) }

        return (0..<AudioLevels.bandCount).map { band in
            let lower = Self.lowestFrequency
                * pow(ratio, Double(band) / Double(AudioLevels.bandCount))
            let upper = Self.lowestFrequency
                * pow(ratio, Double(band + 1) / Double(AudioLevels.bandCount))
            var first = Int((lower / binWidth).rounded(.up))
            var last = Int((upper / binWidth).rounded(.down))
            if last < first {
                // The band is narrower than one bin, which happens at the bottom of the range.
                // Take the bin the band sits inside rather than reporting nothing.
                first = Int(((lower * upper).squareRoot() / binWidth).rounded())
                last = first
            }
            first = min(max(first, 1), lastBin)
            last = min(max(last, first), lastBin)
            return Double(vDSP.maximum(magnitudes[first...last]))
        }
    }
}
