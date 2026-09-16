import AVFoundation
import DictationCore
import Foundation
import Persistence
import XCTest
@testable import PoptartBenchmark

final class BenchmarkTests: XCTestCase {
    func testAudioValidationAndTiming() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("fixture.wav")
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 160))
        buffer.frameLength = 160
        for i in 0..<160 { buffer.floatChannelData![0][i] = 0.25 }
        do {
            let file = try AVAudioFile(forWriting: url, settings: format.settings)
            try file.write(from: buffer)
        }
        let audio = try Audio(url)
        XCTAssertEqual(audio.samples.count, 160)
        XCTAssertEqual(audio.rate, 16_000)
        XCTAssertEqual(audio.samples[0], 0.25)
        XCTAssertThrowsError(try Audio(directory.appendingPathComponent("missing.wav")))
        XCTAssertEqual(try milliseconds(.microseconds(1500)), 1.5)
        XCTAssertThrowsError(try milliseconds(nil))
        XCTAssertThrowsError(try milliseconds(.milliseconds(-1)))
        let memory = try footprint()
        XCTAssertGreaterThan(memory.current, 0)
        XCTAssertGreaterThanOrEqual(memory.peak, memory.current)
    }

    func testRunnerRefusesInvalidInputsWithoutWritingResults() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let fixtures = directory.appendingPathComponent("fixtures.jsonl")
        try Data("{\"id\":\"fixture\"}\n".utf8).write(to: fixtures)
        let outputURL = directory.appendingPathComponent("output.jsonl")
        try Data().write(to: outputURL)
        let output = try FileHandle(forWritingTo: outputURL)
        defer { try? output.close() }
        let base = ["--fixtures", fixtures.path, "--model", directory.path,
                    "--audio", directory.path, "--jsonl"]
        var manifest: [String: Any] = ["identity": "poptart-model-pack", "version": "0.1.0",
            "minimumApplicationVersion": "0.1.0", "maximumApplicationVersion": "0.1.0", "artifacts": []]
        for ceiling in [NSNull(), 100] as [Any] {
            manifest["cleanupTokenCeiling"] = ceiling
            try JSONSerialization.data(withJSONObject: manifest).write(to: directory.appendingPathComponent("manifest.json"))
            for arguments in [base, base + ["--unknown"], base + ["--audio", "/missing"]] {
                do {
                    try await Benchmark.run(arguments: arguments, output: output)
                    XCTFail("Runner accepted invalid prerequisites")
                } catch {}
            }
        }
        XCTAssertTrue(try Data(contentsOf: outputURL).isEmpty)
    }

    func testHarnessPersistsEncryptedHistoryAndReadsWithTheRunKey() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let key = RunKey()
        let store = try HistoryStore(directory: directory, keyProvider: key)
        let context = TargetContext(applicationIdentifier: "benchmark", applicationCategory: .textEditor,
                                    textBeforeCursor: "", textAfterCursor: "", selectedText: nil)
        let harness = Harness(context: context, store: store)
        let intent = DictationRecordIntent(id: .init(), occurredAt: Date(), rawTranscript: "private fixture",
            deliveredText: "Private fixture.", cleanupChanged: true,
            outcome: .cleanedInsertion(method: .accessibility, recordingEnd: .released),
            timings: .init(finalRecognition: .milliseconds(10), cleanup: .milliseconds(20),
                           delivery: .milliseconds(1), completion: .milliseconds(31)),
            destinationApplicationIdentifier: "benchmark")
        await harness.record(intent)
        let readback = try HistoryStore(directory: directory, keyProvider: key)
        let records = try await readback.records()
        XCTAssertEqual(records.first?.deliveredText, intent.deliveredText)
        XCTAssertEqual(records.first?.id, intent.id.rawValue)
        let wrongKey = try HistoryStore(directory: directory, keyProvider: RunKey())
        do {
            _ = try await wrongKey.records()
            XCTFail("History decrypted with the wrong key")
        } catch {}
    }
}
