import CryptoKit
import DictationCore
import Foundation
import ModelRuntime
import SystemIntegration
import Testing

@testable import PoptartApplication

@Suite("Runtime wiring")
struct RuntimeWiringTests {
    @Test("the Cleanup token ceiling comes from the installed pack's manifest")
    func ceilingComesFromInstalledPack() throws {
        let root = try TemporaryDirectory()
        let pack = try root.installPack(version: "2.3.0", cleanupTokenCeiling: 913)

        let located = try #require(try ApplicationModelPackLocator.installedPack(in: root.url))

        #expect(located.cleanupTokenCeiling == 913)
        #expect(located.version == "2.3.0")
        #expect(located.layout.root.standardizedFileURL == pack.standardizedFileURL)
    }

    @Test("a development pack without a manifest reports no measured Cleanup ceiling")
    func developmentPackWithoutManifestHasNoCeiling() throws {
        let root = try TemporaryDirectory()
        let packDirectory = root.url.appendingPathComponent("dev-pack", isDirectory: true)
        try FileManager.default.createDirectory(at: packDirectory, withIntermediateDirectories: true)

        let pack = ApplicationModelPackLocator.developmentPack(at: packDirectory)

        #expect(pack.cleanupTokenCeiling == nil)
        #expect(pack.version == "development (no measured Cleanup ceiling)")
    }

    @Test("a development pack reads its Cleanup ceiling from a manifest beside the artifacts")
    func developmentPackReadsManifest() throws {
        let root = try TemporaryDirectory()
        let packDirectory = root.url.appendingPathComponent("dev-pack", isDirectory: true)
        try FileManager.default.createDirectory(at: packDirectory, withIntermediateDirectories: true)
        let manifest = stubManifest(version: "0.9.0", cleanupTokenCeiling: 512)
        try JSONEncoder().encode(manifest).write(
            to: packDirectory.appendingPathComponent(
                ApplicationModelPackLocator.developmentManifestName))

        let pack = ApplicationModelPackLocator.developmentPack(at: packDirectory)

        #expect(pack.cleanupTokenCeiling == 512)
        #expect(pack.version == "0.9.0 (development)")
    }

    @Test("a pack without a measured ceiling fails Cleanup open to the Raw Transcript")
    func unmeasuredCeilingFailsOpen() async {
        let cleanup = UnmeasuredCleanupBoundary()
        let request = CleanupRequest(
            id: .init(),
            rawTranscript: .init(text: "keep every word"),
            targetContext: .init(
                applicationIdentifier: "com.example.Editor",
                applicationCategory: .textEditor,
                textBeforeCursor: "",
                textAfterCursor: "",
                selectedText: nil
            ),
            personalVocabulary: .init(entries: []),
            deadline: .init(nanoseconds: 0)
        )

        let result = await cleanup.clean(request)

        #expect(result == .rawTranscriptFallback(.modelUnavailable))
    }

    @Test("a recognition-only development pack does not construct a Cleanup model")
    func recognitionOnlyPackSkipsCleanupModel() async throws {
        let root = try TemporaryDirectory()
        let components = try RuntimeCleanupComponents.make(
            modelDirectory: root.url.appendingPathComponent("missing-cleanup"),
            tokenCeiling: nil,
            clock: FixedRuntimeClock()
        )
        let request = CleanupRequest(
            id: .init(),
            rawTranscript: .init(text: "keep every word"),
            targetContext: .init(
                applicationIdentifier: "com.example.Editor",
                applicationCategory: .textEditor,
                textBeforeCursor: "",
                textAfterCursor: "",
                selectedText: nil
            ),
            personalVocabulary: .init(entries: []),
            deadline: .zero
        )

        #expect(components.model == nil)
        #expect(
            await components.boundary.clean(request)
                == .rawTranscriptFallback(.modelUnavailable)
        )
    }

    @Test("a started runtime warms the models, listens, and only then says it is ready")
    func successfulActivationStartsEverything() async throws {
        let activation = RecordingActivation()

        try await RuntimeActivation.activate(activation.steps)

        #expect(activation.warmed.value == 1)
        #expect(activation.pressureStarts.value == 1)
        #expect(activation.shortcutStarts.value == 1)
        #expect(activation.readyPresentations.value == 1)
        #expect(activation.pressureStops.value == 0)
        #expect(activation.shortcutStops.value == 0)
    }

    @Test(
        "a refused shortcut leaves no warm model or pressure monitor running",
        arguments: [
            (ShortcutMonitorStartResult.permissionDenied,
             RuntimeAssemblyError.shortcutPermissionRequired),
            (.eventTapUnavailable, .shortcutUnavailable),
        ]
    )
    func failedActivationStopsWhatItStarted(
        result: ShortcutMonitorStartResult,
        expected: RuntimeAssemblyError
    ) async {
        let activation = RecordingActivation(shortcutResult: result)

        await #expect(throws: expected) {
            try await RuntimeActivation.activate(activation.steps)
        }

        #expect(activation.pressureStarts.value == 1)
        #expect(activation.pressureStops.value == 1, "the monitor that retains the models is stopped")
        #expect(activation.shortcutStops.value == 1)
        #expect(activation.readyPresentations.value == 0, "a runtime that failed never says ready")
    }

    @Test("models that will not load leave no monitor listening")
    func failedWarmupStartsNothing() async {
        let activation = RecordingActivation(warmFailure: StubError("model load"))

        await #expect(throws: StubError.self) {
            try await RuntimeActivation.activate(activation.steps)
        }

        #expect(activation.pressureStarts.value == 0)
        #expect(activation.shortcutStarts.value == 0)
        #expect(activation.readyPresentations.value == 0)
    }

    @Test("shortcut signals reach an observing surface until it is detached")
    func shortcutRelayFansOutSignals() {
        let relay = ShortcutSignalRelay()
        let seen = Box<[ShortcutSignal]>([])
        relay.setObserver { signal in seen.mutate { $0.append(signal) } }

        relay.send(.pressed)
        relay.send(.released)
        relay.setObserver(nil)
        relay.send(.pressed)

        #expect(seen.value == [.pressed, .released])
    }
}

private struct FixedRuntimeClock: MonotonicClock {
    func now() -> MonotonicInstant { .zero }
}

/// A scratch directory that stages a verifiable installed pack the way `ModelPackInstaller` does.
final class TemporaryDirectory {
    let url: URL

    init() throws {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    /// Writes artifacts, a manifest describing them, and the activation record the registry reads.
    @discardableResult
    func installPack(version: String, cleanupTokenCeiling: Int) throws -> URL {
        let packs = url.appendingPathComponent("packs", isDirectory: true)
        let directory = packs.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let license = ModelLicense(
            name: "Apache-2.0",
            url: URL(string: "https://www.apache.org/licenses/LICENSE-2.0")!
        )
        var artifacts: [ModelArtifact] = []
        for role in ModelRole.allCases {
            let relativePath = "\(role.rawValue)/artifact.bin"
            let fileURL = directory.appendingPathComponent(relativePath)
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let bytes = Data("\(role.rawValue)-\(version)".utf8)
            try bytes.write(to: fileURL)
            artifacts.append(
                .init(
                    role: role,
                    url: URL(string: "https://downloads.example.com/\(role.rawValue)")!,
                    relativePath: relativePath,
                    byteSize: Int64(bytes.count),
                    sha256: SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined(),
                    license: license
                ))
        }
        let manifest = try ModelPackManifest(
            identity: "poptart-model-pack",
            version: version,
            minimumApplicationVersion: "0.1.0",
            maximumApplicationVersion: "9.9.9",
            cleanupTokenCeiling: cleanupTokenCeiling,
            artifacts: artifacts
        )
        let state = ActivationRecord(
            current: .init(directory: directory, manifest: manifest), previous: nil)
        try JSONEncoder().encode(state).write(
            to: url.appendingPathComponent("active-model-pack.json"))
        return directory
    }

    deinit {
        try? FileManager.default.removeItem(at: url)
    }

    private struct ActivationRecord: Codable {
        let current: InstalledModelPack
        let previous: InstalledModelPack?
    }
}

/// Counts every startup step so a failed activation can be checked for what it left running.
private final class RecordingActivation: @unchecked Sendable {
    let warmed = Box(0)
    let pressureStarts = Box(0)
    let pressureStops = Box(0)
    let shortcutStarts = Box(0)
    let shortcutStops = Box(0)
    let readyPresentations = Box(0)
    private let shortcutResult: ShortcutMonitorStartResult
    private let warmFailure: (any Error)?

    init(
        shortcutResult: ShortcutMonitorStartResult = .started,
        warmFailure: (any Error)? = nil
    ) {
        self.shortcutResult = shortcutResult
        self.warmFailure = warmFailure
    }

    var steps: RuntimeActivationSteps {
        .init(
            keepWarm: { [self] in
                warmed.mutate { $0 += 1 }
                if let warmFailure { throw warmFailure }
            },
            startPressureMonitoring: { [self] in pressureStarts.mutate { $0 += 1 } },
            stopPressureMonitoring: { [self] in pressureStops.mutate { $0 += 1 } },
            startShortcut: { [self] in
                shortcutStarts.mutate { $0 += 1 }
                return shortcutResult
            },
            stopShortcut: { [self] in shortcutStops.mutate { $0 += 1 } },
            presentReady: { [self] in readyPresentations.mutate { $0 += 1 } }
        )
    }
}
