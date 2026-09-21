import Foundation
import ModelRuntime
import Observation
import SystemIntegration

public struct ModelPackStatus: Equatable, Sendable {
    public let version: String
    public let storageBytes: Int64
    public let licenses: [ModelPackLicenseSummary]
    /// The measured Cleanup budget the pack ships. Nil means the pack carries none, so Cleanup is
    /// off and Dictations keep the Raw Transcript.
    public let cleanupTokenCeiling: Int?
    /// The published version a repair would reinstall. Nil for a development pack Poptart did not
    /// install, which therefore has nothing to reinstall.
    public let repairableVersion: String?

    public init(
        version: String,
        storageBytes: Int64,
        licenses: [ModelPackLicenseSummary],
        cleanupTokenCeiling: Int?,
        repairableVersion: String?
    ) {
        self.version = version
        self.storageBytes = storageBytes
        self.licenses = licenses
        self.cleanupTokenCeiling = cleanupTokenCeiling
        self.repairableVersion = repairableVersion
    }

    public var storageDescription: String {
        ByteSize.description(storageBytes)
    }

    public var cleanupDescription: String {
        cleanupTokenCeiling.map { "Cleanup budget \($0) tokens, measured for this pack." }
            ?? "This pack ships no measured Cleanup budget, so Dictations keep the Raw Transcript."
    }
}

public enum ModelPackActivity: Equatable, Sendable {
    case idle
    case working(ExplicitModelPackAction)
    case reported(String)

    public var isWorking: Bool {
        if case .working = self { return true }
        return false
    }

    public var statusText: String? {
        switch self {
        case .idle:
            nil
        case .working(.onboardingInstall):
            "Installing the Model Pack…"
        case .working(.update):
            "Contacting the release channel…"
        case .working(.repair):
            "Repairing the Model Pack…"
        case .reported(let message):
            message
        }
    }
}

/// Every setting SPEC lists, and nothing that could send anything anywhere on its own. The Model
/// Pack actions and the application update check are the only ones that reach the network, and only
/// when a person starts them.
@MainActor
@Observable
public final class SettingsModel {
    // Microphone
    public private(set) var microphones: [MicrophoneDevice] = []
    public private(set) var selectedMicrophoneIdentifier: String?
    public private(set) var microphoneMessage: String?

    // Dictation shortcut
    public let shortcut: ShortcutBindingModel

    // Launch at login
    public private(set) var launchesAtLogin = false
    public private(set) var launchAtLoginMessage: String?

    // Model Pack
    public private(set) var modelPack: ModelPackStatus?
    public private(set) var modelPackActivity: ModelPackActivity = .idle
    public private(set) var availableModelPack: ModelPackOffer?

    // Personal Vocabulary
    public var vocabularyDraft = ""
    public private(set) var vocabularyMessage: String?

    // Permissions
    public private(set) var permissions: PermissionSnapshot = .unknown

    // History
    public let history: HistoryListModel

    // About
    public private(set) var applicationUpdateMessage: String?
    public let applicationVersion: String
    public let sourceURL = PoptartRelease.sourceURL
    public var historyRetentionDescription: String { history.retentionDescription }

    private let settings: any AppSettingsStoring
    private let deviceEnumerator: any MicrophoneDeviceEnumerating
    private let microphoneRouter: any MicrophoneRouting
    private let microphonePermission: any MicrophonePermissionControlling
    private let accessibilityPermission: any AccessibilityPermission
    private let keyboardPermission: any KeyboardMonitoringPermission
    private let launchAtLogin: any LaunchAtLoginControlling
    private let modelPacks: any ActiveModelPackProviding
    private let manifests: any ModelPackManifestSourcing
    private let offers: any ModelPackOfferDescribing
    private let installer: any ModelPackInstalling
    private let storage: any ModelPackStorageMeasuring
    private let vocabulary: any PersonalVocabularyEditing
    private let applicationUpdate: @MainActor () -> String
    private var activateModelPack: @MainActor () async -> String? = {
        "Restart Poptart to activate the installed Model Pack."
    }

    public func connectModelPackActivation(_ activate: @escaping @MainActor () async -> String?) {
        activateModelPack = activate
    }

    public init(
        shortcut: ShortcutBindingModel,
        history: HistoryListModel,
        settings: any AppSettingsStoring,
        deviceEnumerator: any MicrophoneDeviceEnumerating,
        microphoneRouter: any MicrophoneRouting,
        microphonePermission: any MicrophonePermissionControlling,
        accessibilityPermission: any AccessibilityPermission,
        keyboardPermission: any KeyboardMonitoringPermission,
        launchAtLogin: any LaunchAtLoginControlling,
        modelPacks: any ActiveModelPackProviding,
        manifests: any ModelPackManifestSourcing,
        offers: any ModelPackOfferDescribing,
        installer: any ModelPackInstalling,
        storage: any ModelPackStorageMeasuring,
        vocabulary: any PersonalVocabularyEditing,
        applicationUpdate: @escaping @MainActor () -> String,
        applicationVersion: String = PoptartRelease.version()
    ) {
        self.shortcut = shortcut
        self.history = history
        self.settings = settings
        self.deviceEnumerator = deviceEnumerator
        self.microphoneRouter = microphoneRouter
        self.microphonePermission = microphonePermission
        self.accessibilityPermission = accessibilityPermission
        self.keyboardPermission = keyboardPermission
        self.launchAtLogin = launchAtLogin
        self.modelPacks = modelPacks
        self.manifests = manifests
        self.offers = offers
        self.installer = installer
        self.storage = storage
        self.vocabulary = vocabulary
        self.applicationUpdate = applicationUpdate
        self.applicationVersion = applicationVersion
    }

    public func load() async {
        await refreshMicrophones()
        await refreshPermissions()
        await refreshModelPack()
        await loadVocabulary()
        launchesAtLogin = launchAtLogin.isEnabled()
    }

    // MARK: Microphone

    public func refreshMicrophones() async {
        microphones = deviceEnumerator.devices()
        selectedMicrophoneIdentifier = microphoneRouter.currentInputDeviceIdentifier()
    }

    public func selectMicrophone(_ identifier: String) async {
        do {
            try microphoneRouter.selectInputDevice(identifier: identifier)
            selectedMicrophoneIdentifier = identifier
            microphoneMessage = nil
            try? await settings.setMicrophoneDeviceIdentifier(identifier)
        } catch {
            microphoneMessage = "macOS did not switch to that microphone."
            await refreshMicrophones()
        }
    }

    /// Reapplies the microphone the person chose in Poptart when the Mac starts up on another one.
    public func restorePreferredMicrophone() async {
        guard let preferred = await settings.settings().microphoneDeviceIdentifier else { return }
        guard preferred != microphoneRouter.currentInputDeviceIdentifier() else { return }
        do {
            try microphoneRouter.selectInputDevice(identifier: preferred)
            selectedMicrophoneIdentifier = preferred
        } catch {
            microphoneMessage =
                "The microphone you chose is not connected. Poptart is using the current input device."
        }
    }

    // MARK: Launch at login

    public func setLaunchesAtLogin(_ enabled: Bool) async {
        do {
            try launchAtLogin.setEnabled(enabled)
            launchesAtLogin = launchAtLogin.isEnabled()
            launchAtLoginMessage = nil
        } catch {
            launchesAtLogin = launchAtLogin.isEnabled()
            launchAtLoginMessage = "macOS refused to change the login item."
        }
    }

    // MARK: Permissions

    public func refreshPermissions() async {
        permissions = .init(
            microphone: microphonePermission.state(),
            accessibility: accessibilityPermission.isGranted() ? .granted : .denied,
            keyboardMonitoring: keyboardPermission.isGranted() ? .granted : .denied
        )
    }

    public func requestMissingPermissions() async {
        if !permissions.microphone.isGranted { _ = await microphonePermission.request() }
        if !permissions.accessibility.isGranted { _ = accessibilityPermission.request() }
        if !permissions.keyboardMonitoring.isGranted { _ = keyboardPermission.request() }
        await refreshPermissions()
    }

    // MARK: Model Pack

    public func refreshModelPack() async {
        do {
            guard let pack = try await modelPacks.activePack() else {
                modelPack = nil
                return
            }
            modelPack = .init(
                version: pack.version,
                storageBytes: storage.byteSize(of: pack.layout.root),
                licenses: pack.manifest.map { modelPackLicenseSummaries($0.artifacts) } ?? [],
                cleanupTokenCeiling: pack.cleanupTokenCeiling,
                repairableVersion: pack.origin == .installed
                    ? (pack.manifest?.version ?? pack.version) : nil
            )
        } catch {
            modelPack = nil
            modelPackActivity = .reported(
                "The installed Model Pack no longer verifies. Use Repair Model Pack.")
        }
    }

    /// Asks the release channel what the newest pack is. Nothing downloads until the person then
    /// chooses Update Model Pack.
    public func checkForModelPackUpdate() async {
        modelPackActivity = .working(.update)
        do {
            let offer = try await offer(for: .init(action: .update, version: nil))
            if let installed = modelPack?.version, installed == offer.version {
                availableModelPack = nil
                modelPackActivity = .reported("Poptart already has Model Pack \(offer.version).")
            } else {
                availableModelPack = offer
                modelPackActivity = .reported(
                    "Model Pack \(offer.version) is available (\(ByteSize.description(offer.downloadBytes))).")
            }
        } catch {
            availableModelPack = nil
            modelPackActivity = .reported(ModelPackFailureMessage.text(for: error))
        }
    }

    public func updateModelPack() async {
        guard let offer = availableModelPack else {
            modelPackActivity = .reported("Check for a Model Pack update first.")
            return
        }
        modelPackActivity = .working(.update)
        var failure: String?
        do {
            let installed = try await installer.perform(.update, signedManifest: offer.signedManifest)
            availableModelPack = nil
            let problem = await activateModelPack()
            modelPackActivity = .reported(problem.map { "Model Pack \(installed.manifest.version) is installed. \($0)" }
                ?? "Model Pack \(installed.manifest.version) is active.")
        } catch {
            failure = ModelPackFailureMessage.text(for: error)
        }
        await refreshModelPack()
        if let failure { modelPackActivity = .reported(failure) }
    }

    /// Reinstalls and re-verifies the pack that should be installed, which is what the failure
    /// messages elsewhere in Poptart point people to.
    public func repairModelPack() async {
        // A development pack was never installed from a published manifest, so there is no version
        // to reinstall. An empty or unreadable registry still repairs from the latest manifest,
        // which is what the failure messages elsewhere point people to.
        if let status = modelPack, status.repairableVersion == nil {
            modelPackActivity = .reported(
                "This development Model Pack was not installed by Poptart, so there is nothing to repair."
            )
            return
        }
        modelPackActivity = .working(.repair)
        var failure: String?
        do {
            let request = ModelPackManifestRequest(
                action: .repair, version: modelPack?.repairableVersion)
            let offer = try await offer(for: request)
            let installed = try await installer.perform(
                .repair, signedManifest: offer.signedManifest)
            let problem = await activateModelPack()
            modelPackActivity = .reported(problem.map { "Model Pack \(installed.manifest.version) is installed. \($0)" }
                ?? "Model Pack \(installed.manifest.version) verifies again and is active.")
        } catch {
            failure = ModelPackFailureMessage.text(for: error)
        }
        await refreshModelPack()
        if let failure { modelPackActivity = .reported(failure) }
    }

    // MARK: Personal Vocabulary

    public func loadVocabulary() async {
        do {
            vocabularyDraft = try await vocabulary.terms().joined(separator: "\n")
            vocabularyMessage = nil
        } catch {
            vocabularyDraft = ""
            vocabularyMessage = "Personal Vocabulary cannot be read on this Mac."
        }
    }

    public func saveVocabulary() async {
        let terms = Self.normalize(vocabularyDraft)
        do {
            try await vocabulary.replaceTerms(terms)
            vocabularyDraft = terms.joined(separator: "\n")
            vocabularyMessage = terms.isEmpty
                ? "Personal Vocabulary is empty." : "Saved \(terms.count) terms on this Mac."
        } catch {
            vocabularyMessage = "Personal Vocabulary could not be saved."
        }
    }

    /// One term per line, in the person's own order, without blanks or repeats.
    static func normalize(_ draft: String) -> [String] {
        var seen: Set<String> = []
        return draft.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    // MARK: History

    public func clearHistory() async {
        await history.clearHistory()
    }

    // MARK: About

    /// Called only by the person's explicit Settings action.
    public func checkForApplicationUpdate() {
        applicationUpdateMessage = applicationUpdate()
    }

    private func offer(for request: ModelPackManifestRequest) async throws -> ModelPackOffer {
        try offers.describe(signedManifest: try await manifests.signedManifest(for: request))
    }
}
