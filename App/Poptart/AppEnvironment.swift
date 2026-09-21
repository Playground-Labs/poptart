import Foundation
import ModelRuntime
import Observation
import Persistence
import PoptartApplication
import SystemIntegration

/// Composition root. It builds the stores, adapters, and surface models, owns the runtime, and
/// routes shortcut signals to the onboarding shortcut test. Every decision it could make lives in a
/// model type instead.
@MainActor
@Observable
final class AppEnvironment {
    private(set) var launch: ApplicationLaunchModel!
    let onboarding: OnboardingModel
    let settings: SettingsModel
    let history: HistoryListModel
    let shortcut: ShortcutBindingModel

    private let supportDirectory: URL
    private let settingsStore: AppSettingsStore
    private let historyStore: HistoryStore
    private var retentionTask: Task<Void, Never>?
    private let modelPacks: LocatedModelPackProvider
    private var runtime: RuntimeAssembly?

    /// - Parameter downloader: the resumable downloader Model Pack actions use. ModelRuntime owns
    ///   the only Model Pack component allowed to reach the network, and the repository privacy scan
    ///   forbids naming a network client anywhere under `App/`, so a packaged build injects it here.
    ///   Without one, Model Pack download, update, and repair report that they are unavailable
    ///   instead of pretending to work.
    static func make(
        downloader: (any ResumableArtifactDownloading)? = nil
    ) throws -> AppEnvironment {
        let environment = try AppEnvironment(downloader: downloader)
        environment.launch = ApplicationLaunchModel(
            modelPacks: environment.modelPacks
        ) { [unowned environment] pack in
            try await environment.startRuntime(with: pack)
        }
        environment.settings.connectModelPackActivation { [weak environment] in
            guard let environment else { return "Restart Poptart to activate the installed Model Pack." }
            await environment.launch.restart()
            return environment.launch.status.isReady ? nil : environment.launch.status.message
        }
        return environment
    }

    private init(downloader: (any ResumableArtifactDownloading)?) throws {
        let base = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        var support = base.appendingPathComponent("Playground Labs/Poptart", isDirectory: true)
        #if DEBUG
        // The privacy deny test runs Poptart against a throwaway support directory so a test run
        // cannot read or overwrite a real person's history, the same development-only seam
        // ApplicationModelPackLocator opens for a Model Pack directory.
        if let path = ProcessInfo.processInfo.environment["POPTART_SUPPORT_DIRECTORY"],
           !path.isEmpty
        {
            support = URL(fileURLWithPath: path, isDirectory: true)
        }
        #endif
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        self.supportDirectory = support

        let modelRuntimeDirectory = support.appendingPathComponent("ModelRuntime", isDirectory: true)
        try FileManager.default.createDirectory(
            at: modelRuntimeDirectory, withIntermediateDirectories: true)

        let settingsStore = try AppSettingsStore(directory: support)
        self.settingsStore = settingsStore
        self.modelPacks = LocatedModelPackProvider(modelRuntimeDirectory: modelRuntimeDirectory)

        // The surfaces read the same encrypted files the runtime writes. Both stores write
        // atomically, so a second handle only ever sees a complete record.
        let keyProvider = KeychainEncryptionKeyProvider(service: applicationKeychainService(
            developmentDirectory: ProcessInfo.processInfo.environment["POPTART_SUPPORT_DIRECTORY"]))
        let historyStore = try HistoryStore(directory: support, keyProvider: keyProvider)
        self.historyStore = historyStore
        let vocabularyStore = try PersonalVocabularyStore(
            directory: support, keyProvider: keyProvider)
        let records = HistoryStoreRecords(store: historyStore)

        let microphonePermission = SystemMicrophonePermission()
        let accessibilityPermission = SystemAccessibilityPermission()
        let keyboardPermission = SystemKeyboardMonitoringPermission()

        // Without the app-embedded signing key, or without a downloader, nothing can be verified
        // or fetched, so Model Pack actions report that rather than installing an unverified pack.
        let installer: any ModelPackInstalling
        let manifests: any ModelPackManifestSourcing
        if let downloader, let key = try? ModelPackTrust.embeddedPublicKey() {
            do {
                installer = try ModelPackInstaller(
                    rootDirectory: modelRuntimeDirectory,
                    applicationVersion: PoptartRelease.version(),
                    manifestPublicKey: key,
                    downloader: downloader,
                    smokeTester: LocalModelPackSmokeTest())
                manifests = DownloadedModelPackManifestSource(downloader: downloader)
            } catch {
                let failure = (error as? ModelPackError) ?? .fileSystemFailure
                installer = UnavailableModelPackInstaller(failure: failure)
                manifests = UnavailableModelPackManifestSource(failure: failure)
            }
        } else {
            installer = UnavailableModelPackInstaller()
            manifests = UnavailableModelPackManifestSource()
        }

        let shortcut = ShortcutBindingModel(
            binding: .rightOption,
            settings: settingsStore,
            apply: { _ in }
        )
        self.shortcut = shortcut
        self.history = HistoryListModel(store: records, clipboard: PasteboardTextCopier())
        self.onboarding = OnboardingModel(
            shortcut: shortcut,
            settings: settingsStore,
            microphonePermission: microphonePermission,
            accessibilityPermission: accessibilityPermission,
            keyboardPermission: keyboardPermission,
            modelPacks: modelPacks,
            manifests: manifests,
            offers: VerifiedModelPackOffers(),
            installer: installer,
            readiness: InstalledPackOfflineReadiness(
                modelRuntimeDirectory: modelRuntimeDirectory,
                permissions: {
                    .init(
                        microphone: microphonePermission.state(),
                        accessibility: accessibilityPermission.isGranted() ? .granted : .denied,
                        keyboardMonitoring: keyboardPermission.isGranted() ? .granted : .denied
                    )
                }
            ),
            dictationProbe: records
        )
        let applicationUpdater = ApplicationUpdater()
        self.settings = SettingsModel(
            shortcut: shortcut,
            history: history,
            settings: settingsStore,
            deviceEnumerator: SystemMicrophoneDeviceEnumerator(),
            microphoneRouter: SystemMicrophoneRouter(),
            microphonePermission: microphonePermission,
            accessibilityPermission: accessibilityPermission,
            keyboardPermission: keyboardPermission,
            launchAtLogin: SMAppServiceLaunchAtLogin(),
            modelPacks: modelPacks,
            manifests: manifests,
            offers: VerifiedModelPackOffers(),
            installer: installer,
            storage: FileSystemModelPackStorage(),
            vocabulary: PersonalVocabularyStoreEditor(store: vocabularyStore),
            applicationUpdate: { applicationUpdater.check() }
        )
    }

    /// Loads persisted state, then starts the runtime if a verified pack and the permissions are
    /// already in place. Onboarding runs against the live runtime once it is up.
    func start() async {
        if retentionTask == nil {
            retentionTask = Task { [historyStore] in await historyStore.maintainRetention() }
        }
        await shortcut.load()
        #if DEBUG
        // The privacy deny test has to see settings persistence actually happen while the network
        // is denied, and nothing on a normal launch writes settings on its own. Storing the binding
        // the store just handed back is a real round trip through the real file; it changes nothing
        // the person chose, and it only runs when a throwaway support directory is in force.
        if ProcessInfo.processInfo.environment["POPTART_SUPPORT_DIRECTORY"]?.isEmpty == false {
            try? await settingsStore.setShortcutBinding(shortcut.binding)
        }
        #endif
        await onboarding.load()
        await settings.load()
        await settings.restorePreferredMicrophone()
        await launch.start()
        Task { await history.reload() }
    }

    func refreshAfterExternalChange() async {
        await onboarding.refresh()
        await settings.refreshPermissions()
        await settings.refreshModelPack()
        if !launch.status.isReady, launch.status != .starting { await launch.restart() }
    }

    private func startRuntime(with pack: ActiveApplicationModelPack) async throws {
        // A retry must not leave a second event tap listening for the shortcut.
        await stop()
        let binding = await settingsStore.settings().shortcutBinding
        let runtime = try await RuntimeAssembly.start(
            modelPack: pack.layout,
            applicationSupportDirectory: supportDirectory,
            cleanupTokenCeiling: pack.cleanupTokenCeiling,
            binding: binding
        )
        self.runtime = runtime
        // The Dictation shortcut can be rebound while Poptart runs; the model defers a swap made
        // while the key is held.
        shortcut.connect { [weak runtime] newBinding in
            runtime?.rebindShortcut(to: newBinding)
        }
        runtime.observeShortcutSignals { [weak self] signal in
            Task { @MainActor [weak self] in
                guard let self else { return }
                switch signal {
                case .pressed: self.onboarding.shortcutPressed()
                case .released: await self.onboarding.shortcutReleased()
                }
            }
        }
    }

    func stop() async {
        runtime?.observeShortcutSignals(nil)
        await runtime?.stop()
        runtime = nil
    }

    isolated deinit { retentionTask?.cancel() }
}
