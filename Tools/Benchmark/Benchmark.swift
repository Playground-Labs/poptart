@preconcurrency import AVFoundation
import Cleanup
import CleanupMLX
import CryptoKit
import Darwin
import DictationCore
import Foundation
import ModelRuntime
import Persistence
import PoptartApplication
import Recognition

struct BenchmarkError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

struct Fixture: Decodable {
    struct Context: Decodable {
        let applicationIdentifier: String
        let applicationCategory: String
        let textBeforeCursor: String
        let textAfterCursor: String
        let selectedText: String?
    }
    let id: String
    let vocabularyTerms: [String]?
    let targetContext: Context?

    var context: TargetContext {
        .init(applicationIdentifier: targetContext?.applicationIdentifier ?? "labs.playground.benchmark",
              applicationCategory: targetContext.flatMap { ApplicationCategory(rawValue: $0.applicationCategory) } ?? .textEditor,
              textBeforeCursor: targetContext?.textBeforeCursor ?? "",
              textAfterCursor: targetContext?.textAfterCursor ?? "", selectedText: targetContext?.selectedText)
    }
}

struct Audio {
    let samples: [Float]
    let rate: Double

    init(_ url: URL) throws {
        let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
        let format = file.processingFormat
        guard format.channelCount == 1, format.sampleRate.isFinite, format.sampleRate > 0,
              file.length > 0, Double(file.length) / format.sampleRate < 300,
              file.length <= Int64(UInt32.max),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: UInt32(file.length))
        else { throw BenchmarkError("Audio must be nonempty mono PCM, shorter than 300 seconds: \(url.path)") }
        try file.read(into: buffer)
        guard Int64(buffer.frameLength) == file.length, let channel = buffer.floatChannelData?[0] else {
            throw BenchmarkError("Incomplete audio: \(url.path)")
        }
        samples = Array(UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength)))
        guard samples.allSatisfy(\.isFinite) else { throw BenchmarkError("Non-finite audio samples") }
        rate = format.sampleRate
    }
}

// A per-run key exercises production encryption without touching the person's Keychain.
struct RunKey: EncryptionKeyProviding {
    let key = SymmetricKey(size: .bits256)
    func encryptionKey() throws -> SymmetricKey { key }
    func deleteKey() throws {}
}

actor Harness: InsertionTargetBoundary, TextDeliveryBoundary, IndicatorBoundary, HistoryBoundary {
    let context: TargetContext
    let history: EncryptedHistoryBoundary
    var result: DictationRecordIntent?
    var delivered: String?

    init(context: TargetContext, store: HistoryStore) {
        self.context = context
        history = EncryptedHistoryBoundary(store: store)
    }
    func captureTarget(for id: DictationID) -> Result<DictationTargetCapture, TargetCaptureFailure> {
        .success(.editable(target: .init(applicationIdentifier: context.applicationIdentifier,
                                        elementIdentifier: "benchmark", selection: nil), context: context))
    }
    func revalidateTarget(_ request: TargetRevalidationRequest) -> TargetValidity { .valid }
    func deliver(_ request: DeliveryRequest) -> DeliveryResult {
        delivered = request.text
        return .inserted(.accessibility)
    }
    func copyToClipboard(_ request: ClipboardRequest) -> DeliveryResult { .failed(.clipboardWriteFailed) }
    func cancelDelivery(for id: DictationID) {}
    func present(_ snapshot: IndicatorSnapshot) {}
    func record(_ intent: DictationRecordIntent) async {
        await history.record(intent)
        result = intent
    }
}

func footprint() throws -> (current: UInt64, peak: UInt64) {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(MemoryLayout.size(ofValue: info) / MemoryLayout<integer_t>.size)
    let code = withUnsafeMutablePointer(to: &info) { pointer in
        pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
        }
    }
    guard code == KERN_SUCCESS else { throw BenchmarkError("task_info failed: \(code)") }
    guard info.ledger_phys_footprint_peak > 0 else { throw BenchmarkError("Peak footprint unavailable") }
    return (info.phys_footprint, UInt64(info.ledger_phys_footprint_peak))
}

func milliseconds(_ duration: Duration?) throws -> Double {
    guard let duration, duration >= .zero else { throw BenchmarkError("Missing or negative pipeline timing") }
    return Double(duration.components.seconds) * 1000 + Double(duration.components.attoseconds) / 1e15
}

@main enum Benchmark {
    static func main() async {
        // Third-party inference diagnostics must never contaminate the JSONL stream.
        let output = FileHandle(fileDescriptor: dup(STDOUT_FILENO), closeOnDealloc: true)
        dup2(STDERR_FILENO, STDOUT_FILENO)
        do { try await run(arguments: Array(CommandLine.arguments.dropFirst()), output: output) }
        catch {
            FileHandle.standardError.write(Data("PoptartBenchmark: \(error)\n".utf8))
            exit(1)
        }
    }

    static func run(arguments: [String], output: FileHandle) async throws {
        var args = arguments
        var values: [String: String] = [:]
        var jsonl = false
        while !args.isEmpty {
            let key = args.removeFirst()
            if key == "--jsonl", !jsonl { jsonl = true; continue }
            guard ["--fixtures", "--model", "--audio", "--history-directory"].contains(key),
                  values[key] == nil, !args.isEmpty, !args[0].hasPrefix("--") else {
                throw BenchmarkError("Usage: PoptartBenchmark --fixtures PATH --model DIR --audio DIR --jsonl [--history-directory DIR]")
            }
            values[key] = args.removeFirst()
        }
        guard jsonl, let fixturesPath = values["--fixtures"], let modelPath = values["--model"],
              let audioPath = values["--audio"] else { throw BenchmarkError("--fixtures, --model, --audio and --jsonl are required") }
        let modelRoot = URL(fileURLWithPath: modelPath, isDirectory: true)
        let manifest = try JSONDecoder().decode(ModelPackManifest.self, from: Data(contentsOf: modelRoot.appendingPathComponent("manifest.json")))
        let ceiling = manifest.cleanupTokenCeiling
        let fixtures = try String(contentsOfFile: fixturesPath, encoding: .utf8).split(separator: "\n").map {
            try JSONDecoder().decode(Fixture.self, from: Data($0.utf8))
        }
        guard !fixtures.isEmpty, Set(fixtures.map(\.id)).count == fixtures.count,
              fixtures.allSatisfy({ $0.id.range(of: "^[A-Za-z0-9_-]+$", options: .regularExpression) != nil }) else {
            throw BenchmarkError("Fixture IDs must be unique, nonempty filename-safe identifiers")
        }
        let audioRoot = URL(fileURLWithPath: audioPath, isDirectory: true)
        // Validate every fixture before starting; keep only one decoded recording in memory at a time.
        for fixture in fixtures { _ = try Audio(audioRoot.appendingPathComponent(fixture.id + ".wav")) }
        let layout = ApplicationModelPackLayout(root: modelRoot)
        let relay = DictationEventRelay()
        let clock = ApplicationMonotonicClock()
        let recognition = try RecognitionService(modelLayout: .init(unifiedModelDirectory: layout.unifiedRecognition,
                ctcModelDirectory: layout.optionalCTC, vadModelDirectory: layout.optionalVAD),
                replaying: [0], sampleRate: 16_000, clock: clock,
                onEvent: { await relay.send($0) })
        let cleanupModel = try MLXCleanupModel(modelDirectory: layout.cleanup)
        try await recognition.prepare()
        try await cleanupModel.prepare()
        let cleanup = CleanupEngine(model: cleanupModel, deadlineWaiter: SystemCleanupDeadlineWaiter(clock: clock),
                                    configuration: .init(maximumInputTokens: ceiling))
        let ownedDirectory = values["--history-directory"] == nil
        let directory = values["--history-directory"].map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? FileManager.default.temporaryDirectory.appendingPathComponent("poptart-benchmark-\(UUID())")
        defer { if ownedDirectory { try? FileManager.default.removeItem(at: directory) } }
        if FileManager.default.fileExists(atPath: directory.path),
           try !FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty {
            throw BenchmarkError("History directory must be empty; existing files will not be changed")
        }
        let key = RunKey()
        let store = try HistoryStore(directory: directory, keyProvider: key)
        let settings = try AppSettingsStore(directory: directory)
        try await settings.setMicrophoneDeviceIdentifier("benchmark-fixture")
        let rereadSettings = try AppSettingsStore(directory: directory)
        guard await rereadSettings.settings().microphoneDeviceIdentifier == "benchmark-fixture" else {
            throw BenchmarkError("Settings readback failed")
        }
        for fixture in fixtures {
            let audio = try Audio(audioRoot.appendingPathComponent(fixture.id + ".wav"))
            try await recognition.setReplay(samples: audio.samples, sampleRate: audio.rate)
            let harness = Harness(context: fixture.context, store: store)
            let scheduler = ApplicationDeadlineScheduler(clock: clock, onEvent: { await relay.send($0) })
            let coordinator = DictationCoordinator(session: .init(clock: clock), target: harness,
                speech: recognition, cleanup: cleanup, delivery: harness, indicator: harness,
                history: harness, deadlines: scheduler, vocabulary: { .init(entries: fixture.vocabularyTerms ?? []) })
            await relay.connect(coordinator)
            await coordinator.receive(.pressed)
            try await recognition.waitForReplayCompletion()
            await coordinator.receive(.released)
            let deadline = clock.now().advanced(by: .seconds(10))
            while await harness.result == nil, clock.now() < deadline {
                try await Task.sleep(for: .milliseconds(5))
            }
            await scheduler.cancelAll()
            guard let intent = await harness.result, let text = intent.deliveredText, !text.isEmpty,
                  await harness.delivered == text else { throw BenchmarkError("No completed delivery: \(fixture.id)") }
            let readback = try HistoryStore(directory: directory, keyProvider: key)
            guard let record = try await readback.records().first(where: { $0.id == intent.id.rawValue }),
                  record.deliveredText == text, record.rawTranscript == intent.rawTranscript else {
                throw BenchmarkError("Encrypted history readback failed: \(fixture.id)")
            }
            let memory = try footprint()
            let mlx = await cleanupModel.memoryState
            let bothResident = await recognition.modelsPrepared && mlx.resident
            guard bothResident, mlx.activeBytes > 0 else { throw BenchmarkError("Cleanup model is not resident") }
            let row: [String: Any] = [
                "id": fixture.id, "elapsedMilliseconds": try milliseconds(intent.timings.completion),
                "finalRecognitionMilliseconds": try milliseconds(intent.timings.finalRecognition),
                "cleanupMilliseconds": try milliseconds(intent.timings.cleanup),
                "deliveryMilliseconds": try milliseconds(intent.timings.delivery),
                "outcome": record.outcome.rawValue, "deliveredText": text,
                "footprintBytes": memory.current, "peakFootprintBytes": memory.peak,
                "mlxActiveBytes": mlx.activeBytes, "bothModelsResident": bothResident,
                "historyReadback": true, "settingsReadback": true, "historyRecordID": record.id.uuidString,
                "deliveryMode": "controlled", "cleanupTokenCeiling": ceiling,
                "modelVersion": manifest.version
            ]
            try output.write(contentsOf: JSONSerialization.data(withJSONObject: row, options: [.sortedKeys]))
            try output.write(contentsOf: Data([10]))
        }
    }
}
