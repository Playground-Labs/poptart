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
    public let cleanup: URL

    public init(root: URL) {
        self.root = root.standardizedFileURL
        self.unifiedRecognition = root.appendingPathComponent("recognition/unified", isDirectory: true)
        let ctc = root.appendingPathComponent("recognition/ctc", isDirectory: true)
        self.optionalCTC = FileManager.default.fileExists(atPath: ctc.path) ? ctc : nil
        self.cleanup = root.appendingPathComponent("cleanup", isDirectory: true)
    }
}

public struct ActiveApplicationModelPack: Equatable, Sendable {
    public let layout: ApplicationModelPackLayout
    public let cleanupTokenCeiling: Int
    public let version: String

    public init(layout: ApplicationModelPackLayout, cleanupTokenCeiling: Int, version: String) {
        self.layout = layout
        self.cleanupTokenCeiling = cleanupTokenCeiling
        self.version = version
    }
}

public enum ApplicationModelPackLocator {
    public static func activePack(in modelRuntimeDirectory: URL) throws -> ActiveApplicationModelPack? {
        #if DEBUG
        if let path = ProcessInfo.processInfo.environment["POPTART_MODEL_PACK_DIRECTORY"],
           !path.isEmpty
        {
            return .init(
                layout: .init(root: URL(fileURLWithPath: path, isDirectory: true)),
                cleanupTokenCeiling: 1_024,
                version: "development"
            )
        }
        #endif
        guard let installed = try InstalledModelPackRegistry(
            rootDirectory: modelRuntimeDirectory
        ).activePack() else { return nil }
        return .init(
            layout: .init(root: installed.directory),
            cleanupTokenCeiling: installed.manifest.cleanupTokenCeiling,
            version: installed.manifest.version
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
    private let cleanupModel: MLXCleanupModel
    private let shortcut: RightOptionShortcutMonitor
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
        cleanupModel: MLXCleanupModel,
        shortcut: RightOptionShortcutMonitor,
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
        self.residency = residency
        self.pressureMonitor = pressureMonitor
    }

    public static func start(
        modelPack: ApplicationModelPackLayout,
        applicationSupportDirectory: URL,
        cleanupTokenCeiling: Int = 1_024,
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
                ctcModelDirectory: modelPack.optionalCTC
            ),
            clock: clock,
            onEvent: { [relay] event in await relay.send(event) }
        )
        let cleanupModel = try MLXCleanupModel(modelDirectory: modelPack.cleanup)
        let modelLoader = ApplicationModelLoader(
            recognition: recognition,
            cleanup: cleanupModel
        )
        let residency = ModelResidencyController(loader: modelLoader)
        let pressureMonitor = MacOSMemoryPressureMonitor()
        let cleanup = CleanupEngine(
            model: cleanupModel,
            deadlineWaiter: SystemCleanupDeadlineWaiter(clock: clock),
            configuration: .init(maximumInputTokens: cleanupTokenCeiling)
        )
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
            cleanup: cleanup,
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
        let shortcut = RightOptionShortcutMonitor { signal in
            let gesture: DictationGesture = signal == .pressed ? .pressed : .released
            Task { await coordinator.receive(gesture) }
        }
        let assembly = RuntimeAssembly(
            coordinator: coordinator,
            accessibility: accessibility,
            historyStore: historyStore,
            vocabularyStore: vocabularyStore,
            relay: relay,
            scheduler: scheduler,
            recognition: recognition,
            cleanupModel: cleanupModel,
            shortcut: shortcut,
            residency: residency,
            pressureMonitor: pressureMonitor
        )

        try await residency.keepWarm()
        pressureMonitor.start { [residency] pressure in
            Task { await residency.handleMemoryPressure(pressure) }
        }
        await indicator.present(.init(dictationID: nil, state: .ready))

        switch shortcut.start(requestPermission: false) {
        case .started, .alreadyStarted:
            return assembly
        case .permissionDenied:
            throw RuntimeAssemblyError.shortcutPermissionRequired
        case .eventTapUnavailable:
            throw RuntimeAssemblyError.shortcutUnavailable
        }
    }

    public func stop() async {
        shortcut.stop()
        pressureMonitor.stop()
        await scheduler.cancelAll()
    }

    public func requestAccessibilityPermission() -> Bool {
        accessibility.requestPermission()
    }

    public static func microphonePermission() -> AVAuthorizationStatus {
        AVCaptureDevice.authorizationStatus(for: .audio)
    }

    public static func requestMicrophonePermission() async -> Bool {
        await AVCaptureDevice.requestAccess(for: .audio)
    }
}

private actor ApplicationModelLoader: ManagedModelLoading {
    let recognition: RecognitionService
    let cleanup: MLXCleanupModel

    init(recognition: RecognitionService, cleanup: MLXCleanupModel) {
        self.recognition = recognition
        self.cleanup = cleanup
    }

    func load(_ role: ModelRole) async throws {
        switch role {
        case .recognition:
            try await recognition.prepare()
        case .cleanup:
            try await cleanup.prepare()
        }
    }

    func unload(_ role: ModelRole) async {
        guard role == .cleanup else { return }
        await cleanup.unload()
    }
}
