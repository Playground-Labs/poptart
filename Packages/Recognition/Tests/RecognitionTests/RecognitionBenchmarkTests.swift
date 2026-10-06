@preconcurrency import AVFoundation
import Darwin
import DictationCore
import Foundation
import XCTest
@testable import Recognition

/// An explicit local experiment, never a release gate or an ordinary test dependency.
final class RecognitionBenchmarkTests: XCTestCase {
    func testReplayLocalSpeech() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let manifestPath = environment["POPTART_RECOGNITION_BENCHMARK"] else {
            throw XCTSkip("Set POPTART_RECOGNITION_BENCHMARK to an explicit local manifest")
        }
        let manifestURL = URL(fileURLWithPath: manifestPath)
        let manifest = try JSONDecoder().decode(ReplayManifest.self, from: Data(contentsOf: manifestURL))
        try manifest.validate()
        let base = manifestURL.deletingLastPathComponent()
        func resolve(_ path: String) -> URL {
            URL(fileURLWithPath: path, relativeTo: base).standardizedFileURL
        }
        let layout = RecognitionModelLayout(
            unifiedModelDirectory: resolve(manifest.modelDirectory),
            ctcModelDirectory: manifest.ctcDirectory.map(resolve),
            vadModelDirectory: manifest.vadDirectory.map(resolve)
        )
        let clock = UptimeMonotonicClock()
        let recognizer = FluidAudioIncrementalRecognizer(modelLayout: layout, clock: clock)
        let prepareStart = clock.now()
        try await recognizer.prepare()
        let prepareMilliseconds = milliseconds(prepareStart, clock.now())
        var rows: [ReplayRow] = []

        for fixture in manifest.fixtures {
            // Decode outside the timed region. Only explicitly supplied, licensed test speech
            // belongs here; the app's private recordings are never consulted.
            let file = try AVAudioFile(forReading: resolve(fixture.audio))
            guard file.length > 0, file.processingFormat.sampleRate == 16_000,
                  file.processingFormat.channelCount == 1 else {
                throw ReplayError.invalid("Audio must be nonempty 16 kHz mono: \(fixture.id)")
            }
            var buffers: [RecognitionAudioBuffer] = []
            while file.framePosition < file.length {
                let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 1_600))
                try file.read(into: buffer, frameCount: 1_600)
                guard buffer.frameLength > 0 else { throw ReplayError.invalid("Unexpected audio EOF") }
                buffers.append(.init(buffer: buffer, audioActivity: nil))
            }
            let duration = Double(file.length) / 16_000
            for iteration in 1...manifest.repetitions {
                let partial = FirstPartial()
                try await recognizer.begin(personalVocabulary: .init(entries: fixture.vocabulary)) { text in
                    partial.record(text, at: clock.now())
                }
                let start = clock.now()
                let keyUp = start.advanced(by: .seconds(duration))
                var frames: Int64 = 0
                for buffer in buffers {
                    frames += Int64(buffer.buffer.frameLength)
                    // Deliver each chunk only when capture would have produced its last frame.
                    // Schedule against one origin so slow inference cannot move simulated key-up.
                    let arrival = start.advanced(by: .seconds(Double(frames) / 16_000))
                    let wait = clock.now().duration(to: arrival)
                    if wait > .zero { try await Task.sleep(for: wait) }
                    try await recognizer.accept(buffer)
                }
                let result = await recognizer.finish(deadline: keyUp.advanced(by: .milliseconds(1_500)))
                let finish = clock.now()
                let text: String
                let outcome: String
                switch result {
                case .final(let final): (text, outcome) = (final, "final")
                case .deadlineFallback(let hypothesis): (text, outcome) = (hypothesis ?? "", "hypothesisFallback")
                case .failed(let error): (text, outcome) = ("", "failed:\(error)")
                }
                rows.append(.init(
                    id: fixture.id, iteration: iteration, audioSeconds: duration,
                    firstPartialMilliseconds: partial.instant.map { milliseconds(start, $0) },
                    keyUpToResultMilliseconds: milliseconds(keyUp, finish), outcome: outcome,
                    reference: fixture.reference, transcript: text,
                    wordErrorRate: wordErrorRate(reference: fixture.reference, hypothesis: text),
                    vocabulary: fixture.vocabulary
                ))
            }
        }
        await recognizer.cancel()
        var usage = rusage()
        guard getrusage(RUSAGE_SELF, &usage) == 0 else { throw ReplayError.invalid("getrusage failed") }
        let report = ReplayReport(
            schemaVersion: 1, releaseQualified: false,
            scope: "Warm recognizer replay only; excludes microphone, Cleanup and insertion",
            os: ProcessInfo.processInfo.operatingSystemVersionString,
            hardware: try hardwareString("machdep.cpu.brand_string"),
            physicalMemoryBytes: ProcessInfo.processInfo.physicalMemory,
            processPeakResidentBytes: Int64(usage.ru_maxrss),
            prepareMilliseconds: prepareMilliseconds,
            modelDirectory: layout.unifiedModelDirectory.path,
            ctcDirectory: layout.ctcModelDirectory?.path, vadDirectory: layout.vadModelDirectory?.path,
            rows: rows
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(report).write(to: resolve(manifest.output), options: .atomic)
        print("Recognition replay report written: \(resolve(manifest.output).path)")
    }

    func testWordErrorScoringAndManifestValidation() throws {
        XCTAssertEqual(wordErrorRate(reference: "Hello, WORLD!", hypothesis: "hello world"), 0)
        XCTAssertEqual(wordErrorRate(reference: "one two", hypothesis: "one three four"), 1)
        XCTAssertEqual(wordErrorRate(reference: "one two", hypothesis: ""), 1)
        XCTAssertEqual(wordErrorRate(reference: "one two three", hypothesis: "one three"), 1.0 / 3)
        let fixture = ReplayFixture(id: "speech", audio: "speech.wav", reference: "Hello", vocabulary: [])
        var manifest = ReplayManifest(modelDirectory: "model", ctcDirectory: nil, vadDirectory: nil,
                                      repetitions: 1, output: "report.json", fixtures: [fixture])
        XCTAssertNoThrow(try manifest.validate())
        manifest.fixtures.append(fixture)
        XCTAssertThrowsError(try manifest.validate())
        manifest.fixtures = []
        XCTAssertThrowsError(try manifest.validate())
        manifest.fixtures = [fixture]
        manifest.repetitions = 0
        XCTAssertThrowsError(try manifest.validate())
        manifest.repetitions = 1
        manifest.fixtures = [.init(id: "vocab", audio: "speech.wav", reference: "Hello", vocabulary: ["Poptart"])]
        XCTAssertThrowsError(try manifest.validate())
        manifest.ctcDirectory = "ctc"
        XCTAssertNoThrow(try manifest.validate())
    }
}

private enum ReplayError: Error { case invalid(String) }

private struct ReplayManifest: Decodable {
    var modelDirectory: String
    var ctcDirectory: String?
    var vadDirectory: String?
    var repetitions: Int
    var output: String
    var fixtures: [ReplayFixture]

    func validate() throws {
        guard repetitions > 0, !fixtures.isEmpty, !modelDirectory.isEmpty, !output.isEmpty,
              Set(fixtures.map(\.id)).count == fixtures.count,
              fixtures.allSatisfy({ !$0.id.isEmpty && !$0.audio.isEmpty && !words($0.reference).isEmpty }),
              ctcDirectory != nil || fixtures.allSatisfy({ $0.vocabulary.isEmpty }) else {
            throw ReplayError.invalid("Require positive repetitions, unique nonempty speech fixtures, paths, and CTC assets for vocabulary")
        }
    }
}

private struct ReplayFixture: Decodable {
    let id: String
    let audio: String
    let reference: String
    let vocabulary: [String]
}

private struct ReplayRow: Encodable {
    let id: String
    let iteration: Int
    let audioSeconds: Double
    let firstPartialMilliseconds: Double?
    let keyUpToResultMilliseconds: Double
    let outcome: String
    let reference: String
    let transcript: String
    let wordErrorRate: Double
    let vocabulary: [String]
}

private struct ReplayReport: Encodable {
    let schemaVersion: Int
    let releaseQualified: Bool
    let scope: String
    let os: String
    let hardware: String
    let physicalMemoryBytes: UInt64
    let processPeakResidentBytes: Int64
    let prepareMilliseconds: Double
    let modelDirectory: String
    let ctcDirectory: String?
    let vadDirectory: String?
    let rows: [ReplayRow]
}

private final class FirstPartial: @unchecked Sendable {
    private let lock = NSLock()
    private var first: MonotonicInstant?
    var instant: MonotonicInstant? { lock.withLock { first } }
    func record(_ text: String, at instant: MonotonicInstant) {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        lock.withLock { if first == nil { first = instant } }
    }
}

private func milliseconds(_ start: MonotonicInstant, _ end: MonotonicInstant) -> Double {
    Double(end.nanoseconds - start.nanoseconds) / 1_000_000
}

private func hardwareString(_ key: String) throws -> String {
    var size = 0
    guard sysctlbyname(key, nil, &size, nil, 0) == 0 else { throw ReplayError.invalid("Missing hardware identity") }
    var bytes = [UInt8](repeating: 0, count: size)
    guard sysctlbyname(key, &bytes, &size, nil, 0) == 0 else { throw ReplayError.invalid("Missing hardware identity") }
    return String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self)
}

private func words(_ text: String) -> [String] {
    text.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
}

private func wordErrorRate(reference: String, hypothesis: String) -> Double {
    let reference = words(reference)
    let hypothesis = words(hypothesis)
    var previous = Array(0...hypothesis.count)
    for (i, expected) in reference.enumerated() {
        var row = [i + 1]
        for (j, actual) in hypothesis.enumerated() {
            row.append(min(previous[j + 1] + 1, row[j] + 1, previous[j] + (expected == actual ? 0 : 1)))
        }
        previous = row
    }
    return Double(previous.last!) / Double(max(1, reference.count))
}
