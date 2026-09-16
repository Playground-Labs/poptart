@preconcurrency import AVFoundation
import Cleanup
import CleanupMLX
import DictationCore
import Foundation
import ModelRuntime
import Persistence
import Recognition
import SystemIntegration

public struct ApplicationModelPackLayout: Equatable, Sendable {
    public let root: URL
    public let unifiedRecognition: URL
    public let optionalCTC: URL?
    public let optionalVAD: URL?
    public let cleanup: URL

    public init(root: URL) {
        self.root = root.standardizedFileURL
        self.unifiedRecognition = root.appendingPathComponent("recognition/unified", isDirectory: true)
        let ctc = root.appendingPathComponent("recognition/ctc", isDirectory: true)
        self.optionalCTC = FileManager.default.fileExists(atPath: ctc.path) ? ctc : nil
        let vad = root.appendingPathComponent("vad", isDirectory: true)
        self.optionalVAD = FileManager.default.fileExists(atPath: vad.path) ? vad : nil
        self.cleanup = root.appendingPathComponent("cleanup", isDirectory: true)
    }
}

/// Where the active pack came from. Only a pack the installer activated can be repaired, because
/// only that pack has a published version to reinstall.
public enum ModelPackOrigin: Equatable, Sendable {
    case installed
    case development
}

public struct ActiveApplicationModelPack: Equatable, Sendable {
    public let layout: ApplicationModelPackLayout
    /// The Cleanup token ceiling measured for this pack release, or nil when the pack carries no
    /// measured ceiling. The application never substitutes a default: an absent ceiling disables
    /// model Cleanup instead of inventing a budget the release never measured.
    public let cleanupTokenCeiling: Int?
    public let version: String
    public let manifest: ModelPackManifest?
    public let origin: ModelPackOrigin

    public init(
        layout: ApplicationModelPackLayout,
        cleanupTokenCeiling: Int?,
        version: String,
        manifest: ModelPackManifest? = nil,
        origin: ModelPackOrigin = .installed
    ) {
        self.layout = layout
        self.cleanupTokenCeiling = cleanupTokenCeiling
        self.version = version
        self.manifest = manifest
        self.origin = origin
    }
}

public enum ApplicationModelPackLocator {
    /// The manifest a development pack directory may carry so the measured Cleanup ceiling still
    /// comes from a pack description rather than from application code.
    static let developmentManifestName = "manifest.json"

    public static func activePack(
        in modelRuntimeDirectory: URL
    ) throws -> ActiveApplicationModelPack? {
        #if DEBUG
        if let path = ProcessInfo.processInfo.environment["POPTART_MODEL_PACK_DIRECTORY"],
           !path.isEmpty
        {
            return developmentPack(at: URL(fileURLWithPath: path, isDirectory: true))
        }
        #endif
        return try installedPack(in: modelRuntimeDirectory)
    }

    static func installedPack(in modelRuntimeDirectory: URL) throws -> ActiveApplicationModelPack? {
        guard let installed = try InstalledModelPackRegistry(
            rootDirectory: modelRuntimeDirectory
        ).activePack() else { return nil }
        return .init(
            layout: .init(root: installed.directory),
            cleanupTokenCeiling: installed.cleanupTokenCeiling,
            version: installed.manifest.version,
            manifest: installed.manifest,
            origin: .installed
        )
    }

    /// Describes an unpacked development directory. A `ModelPackManifest` beside the artifacts
    /// supplies the measured ceiling; without one the pack runs with Cleanup disabled rather than
    /// with a fabricated ceiling.
    static func developmentPack(at root: URL) -> ActiveApplicationModelPack {
        let manifestURL = root.appendingPathComponent(developmentManifestName)
        let manifest = (try? Data(contentsOf: manifestURL))
            .flatMap { try? JSONDecoder().decode(ModelPackManifest.self, from: $0) }
        return .init(
            layout: .init(root: root),
            cleanupTokenCeiling: manifest?.cleanupTokenCeiling,
            version: manifest.map { "\($0.version) (development)" }
                ?? "development (no measured Cleanup ceiling)",
            manifest: manifest,
            origin: .development
        )
    }
}

public enum RuntimeAssemblyError: Error, Equatable, Sendable {
    case modelPackMissing
    case microphonePermissionRequired
    case accessibilityPermissionRequired
    case shortcutPermissionRequired
    case shortcutUnavailable
}

/// Retains the warm model services and every process-lifetime integration adapter.
public final class RuntimeAssembly: @unchecked Sendable {
    public let coordinator: DictationCoordinator
    public let accessibility: AccessibilityTextService
    public let historyStore: HistoryStore
    public let vocabularyStore: PersonalVocabularyStore

    private let relay: DictationEventRelay
    private let scheduler: ApplicationDeadlineScheduler
    private let recognition: RecognitionService
    private let cleanupModel: MLXCleanupModel?
    private let shortcut: DictationShortcutMonitor
    private let shortcutRelay: ShortcutSignalRelay
    private let residency: ModelResidencyController
    private let pressureMonitor: MacOSMemoryPressureMonitor

    private init(
        coordinator: DictationCoordinator,
        accessibility: AccessibilityTextService,
        historyStore: HistoryStore,
        vocabularyStore: PersonalVocabularyStore,
        relay: DictationEventRelay,
        scheduler: ApplicationDeadlineScheduler,
        recognition: RecognitionService,
        cleanupModel: MLXCleanupModel?,
        shortcut: DictationShortcutMonitor,
        shortcutRelay: ShortcutSignalRelay,
        residency: ModelResidencyController,
        pressureMonitor: MacOSMemoryPressureMonitor
    ) {
        self.coordinator = coordinator
        self.accessibility = accessibility
        self.historyStore = historyStore
        self.vocabularyStore = vocabularyStore
        self.relay = relay
        self.scheduler = scheduler
        self.recognition = recognition
        self.cleanupModel = cleanupModel
        self.shortcut = shortcut
        self.shortcutRelay = shortcutRelay
        self.residency = residency
        self.pressureMonitor = pressureMonitor
    }

    /// - Parameter cleanupTokenCeiling: the ceiling the active pack measured, or nil when the pack
    ///   carries none. A nil ceiling takes the same path as a missing Cleanup model: every
    ///   Dictation fails open to the Raw Transcript instead of running against an invented budget.
    @MainActor
    public static func start(
        modelPack: ApplicationModelPackLayout,
        applicationSupportDirectory: URL,
        cleanupTokenCeiling: Int?,
        binding: ShortcutBinding = .rightOption,
        requestKeyboardPermission: Bool = false
    ) async throws -> RuntimeAssembly {
        guard FileManager.default.fileExists(atPath: modelPack.root.path) else {
            throw RuntimeAssemblyError.modelPackMissing
        }
        guard microphonePermission() == .authorized else {
            throw RuntimeAssemblyError.microphonePermissionRequired
        }
        guard SystemAccessibilityPermission().isGranted() else {
            throw RuntimeAssemblyError.accessibilityPermissionRequired
        }
        let keyboardPermission = SystemKeyboardMonitoringPermission()
        guard keyboardPermission.isGranted()
            || (requestKeyboardPermission && keyboardPermission.request())
        else {
            throw RuntimeAssemblyError.shortcutPermissionRequired
        }
        let clock = ApplicationMonotonicClock()
        let relay = DictationEventRelay()
        let scheduler = ApplicationDeadlineScheduler(
            clock: clock,
            onEvent: { [relay] event in await relay.send(event) }
        )
        let recognition = try RecognitionService(
            modelLayout: .init(
                unifiedModelDirectory: modelPack.unifiedRecognition,
                ctcModelDirectory: modelPack.optionalCTC,
                vadModelDirectory: modelPack.optionalVAD
            ),
            clock: clock,
            onEvent: { [relay] event in await relay.send(event) }
        )
        let cleanupComponents = try RuntimeCleanupComponents.make(
            modelDirectory: modelPack.cleanup,
            tokenCeiling: cleanupTokenCeiling,
            clock: clock
        )
        let modelLoader = ApplicationModelLoader(
            recognition: recognition,
            cleanup: cleanupComponents.model
        )
        let residency = ModelResidencyController(loader: modelLoader)
        let pressureMonitor = MacOSMemoryPressureMonitor()
        let accessibility = AccessibilityTextService()
        let indicator = IndicatorPresenter()
        let keyProvider = KeychainEncryptionKeyProvider(service: "labs.playground.Poptart")
        let historyStore = try HistoryStore(
            directory: applicationSupportDirectory,
            keyProvider: keyProvider
        )
        let vocabularyStore = try PersonalVocabularyStore(
            directory: applicationSupportDirectory,
            keyProvider: keyProvider
        )
        let history = EncryptedHistoryBoundary(store: historyStore)
        let coordinator = DictationCoordinator(
            session: .init(clock: clock),
            target: accessibility,
            speech: recognition,
            cleanup: cleanupComponents.boundary,
            delivery: accessibility,
            indicator: indicator,
            history: history,
            deadlines: scheduler,
            vocabulary: { [vocabularyStore] in
                let terms = (try? await vocabularyStore.terms()) ?? []
                return .init(entries: terms)
            },
            prepareForRecording: { [residency] in
                try? await residency.recordingDidBegin()
            }
        )
        await relay.connect(coordinator)
        let shortcutRelay = ShortcutSignalRelay()
        let shortcut = DictationShortcutMonitor(binding: binding) { signal in
            let gesture: DictationGesture = signal == .pressed ? .pressed : .released
            DispatchQueue.main.async {
                Task { await coordinator.receive(gesture) }
            }
            shortcutRelay.send(signal)
        }
        let assembly = RuntimeAssembly(
            coordinator: coordinator,
            accessibility: accessibility,
            historyStore: historyStore,
            vocabularyStore: vocabularyStore,
            relay: relay,
            scheduler: scheduler,
            recognition: recognition,
            cleanupModel: cleanupComponents.model,
            shortcut: shortcut,
            shortcutRelay: shortcutRelay,
            residency: residency,
            pressureMonitor: pressureMonitor
        )

        try await RuntimeActivation.activate(
            .init(
                keepWarm: { try await residency.keepWarm() },
                startPressureMonitoring: {
                    pressureMonitor.start { [residency] pressure in
                        Task { await residency.handleMemoryPressure(pressure) }
                    }
                },
                stopPressureMonitoring: { pressureMonitor.stop() },
                startShortcut: { shortcut.start(requestPermission: false) },
                stopShortcut: { shortcut.stop() },
                presentReady: { await indicator.present(.init(dictationID: nil, state: .ready)) }
            )
        )
        return assembly
    }

    public func stop() async {
        shortcutRelay.setObserver(nil)
        shortcut.stop()
        pressureMonitor.stop()
        await scheduler.cancelAll()
    }

    /// The key currently held to dictate.
    public var shortcutBinding: ShortcutBinding { shortcut.binding }

    /// Moves the live Dictation shortcut to another key. A gesture already in flight is released
    /// by the monitor before the swap takes effect.
    public func rebindShortcut(to binding: ShortcutBinding) {
        shortcut.rebind(to: binding)
    }

    /// Mirrors shortcut press and release signals to a surface, such as the onboarding shortcut
    /// test. The observer runs on the event-tap thread and never receives transcript text.
    public func observeShortcutSignals(_ observer: (@Sendable (ShortcutSignal) -> Void)?) {
        shortcutRelay.setObserver(observer)
    }

    public static func microphonePermission() -> AVAuthorizationStatus {
        AVCaptureDevice.authorizationStatus(for: .audio)
    }
}

/// The startup steps that outlive the call that performs them: warm models, memory-pressure
/// monitoring, and the shortcut event tap.
struct RuntimeActivationSteps: Sendable {
    let keepWarm: @Sendable () async throws -> Void
    let startPressureMonitoring: @Sendable () -> Void
    let stopPressureMonitoring: @Sendable () -> Void
    let startShortcut: @Sendable () -> ShortcutMonitorStartResult
    let stopShortcut: @Sendable () -> Void
    let presentReady: @Sendable () async -> Void
}

enum RuntimeActivation {
    /// Brings the runtime up as one transaction: everything this started is stopped again before an
    /// error leaves, so a refused shortcut never strands a warm model or a pressure monitor that
    /// nothing can reach to stop. The Indicator only says ready once the shortcut is listening.
    static func activate(_ steps: RuntimeActivationSteps) async throws {
        try await steps.keepWarm()
        steps.startPressureMonitoring()
        let failure: RuntimeAssemblyError?
        switch steps.startShortcut() {
        case .started, .alreadyStarted: failure = nil
        case .permissionDenied: failure = .shortcutPermissionRequired
        case .eventTapUnavailable: failure = .shortcutUnavailable
        }
        if let failure {
            steps.stopShortcut()
            steps.stopPressureMonitoring()
            throw failure
        }
        await steps.presentReady()
    }
}

/// Fails Cleanup open when the active pack ships no measured token ceiling, so the Dictation keeps
/// every recognized word instead of running the model against a budget nobody measured.
struct UnmeasuredCleanupBoundary: CleanupBoundary {
    func clean(_ request: CleanupRequest) async -> CleanupResult {
        .rawTranscriptFallback(.modelUnavailable)
    }

    func cancelCleanup(for id: DictationID) async {}
}

struct RuntimeCleanupComponents {
    let boundary: any CleanupBoundary
    let model: MLXCleanupModel?

    static func make(
        modelDirectory: URL,
        tokenCeiling: Int?,
        clock: any MonotonicClock
    ) throws -> Self {
        guard let tokenCeiling else {
            return .init(boundary: UnmeasuredCleanupBoundary(), model: nil)
        }
        let model = try MLXCleanupModel(modelDirectory: modelDirectory)
        return .init(
            boundary: CleanupEngine(
                model: model,
                deadlineWaiter: SystemCleanupDeadlineWaiter(clock: clock),
                configuration: .init(maximumInputTokens: tokenCeiling)
            ),
            model: model
        )
    }
}

/// Fans shortcut signals out to a surface without giving it the monitor itself.
final class ShortcutSignalRelay: @unchecked Sendable {
    private let lock = NSLock()
    private var observer: (@Sendable (ShortcutSignal) -> Void)?

    func setObserver(_ observer: (@Sendable (ShortcutSignal) -> Void)?) {
        lock.withLock { self.observer = observer }
    }

    func send(_ signal: ShortcutSignal) {
        let observer = lock.withLock { self.observer }
        observer?(signal)
    }
}

private actor ApplicationModelLoader: ManagedModelLoading {
    let recognition: RecognitionService
    let cleanup: MLXCleanupModel?

    init(recognition: RecognitionService, cleanup: MLXCleanupModel?) {
        self.recognition = recognition
        self.cleanup = cleanup
    }

    func load(_ role: ModelRole) async throws {
        switch role {
        case .recognition:
            try await recognition.prepare()
        case .cleanup:
            try await cleanup?.prepare()
        }
    }

    func unload(_ role: ModelRole) async {
        guard role == .cleanup else { return }
        await cleanup?.unload()
    }
}
