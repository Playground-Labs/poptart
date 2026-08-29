import AppKit
@preconcurrency import AVFoundation
import CleanupMLX
import CoreAudio
import Foundation
import ModelRuntime
import Persistence
import Recognition
import ServiceManagement
import SystemIntegration

// Thin macOS implementations of the surface boundaries. They contain no decisions: every choice
// they could make belongs to a model type that tests can drive with a fake instead.

/// Release identity the surfaces display. Packaging supplies the real values through Info.plist;
/// the fallbacks describe an unpackaged development build.
public enum PoptartRelease {
    static let fallbackVersion = "0.1.0"

    public static func version(bundle: Bundle = .main) -> String {
        bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
            ?? fallbackVersion
    }

    public static let sourceURL = URL(string: "https://github.com/playground-labs/poptart")!
    public static let releasesURL = URL(
        string: "https://github.com/playground-labs/poptart/releases")!
    public static let modelPackManifestBaseURL = URL(
        string: "https://downloads.playgroundlabs.com/poptart/model-pack")!
}

public enum ModelPackTrustError: Error, Equatable, Sendable {
    case signingKeyMissing
}

/// Supplies the app-embedded public key that verifies Model Pack manifests. The key ships with the
/// packaged application, never with source, so a build without one refuses every Model Pack action
/// rather than trusting an unverified manifest.
public enum ModelPackTrust {
    public static let infoPlistKey = "PoptartModelPackPublicKey"

    public static func embeddedPublicKey(bundle: Bundle = .main) throws -> Data {
        guard let encoded = bundle.object(forInfoDictionaryKey: infoPlistKey) as? String,
              let key = Data(base64Encoded: encoded),
              key.count == 32
        else { throw ModelPackTrustError.signingKeyMissing }
        return key
    }
}

public struct SystemMicrophonePermission: MicrophonePermissionControlling {
    public init() {}

    public func state() -> PermissionState {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: .granted
        case .notDetermined: .undetermined
        default: .denied
        }
    }

    @discardableResult
    public func request() async -> Bool {
        await AVCaptureDevice.requestAccess(for: .audio)
    }
}

public struct SystemMicrophoneDeviceEnumerator: MicrophoneDeviceEnumerating {
    public init() {}

    public func devices() -> [MicrophoneDevice] {
        AVCaptureDevice.DiscoverySession(
            deviceTypes: [.microphone, .external],
            mediaType: .audio,
            position: .unspecified
        ).devices.map { .init(id: $0.uniqueID, name: $0.localizedName) }
    }
}

/// Selects the Mac's audio input device. Recognition captures from the input device, so this is
/// what choosing a microphone in Poptart means.
public struct SystemMicrophoneRouter: MicrophoneRouting {
    public enum RouterError: Error, Equatable, Sendable {
        case deviceNotFound
        case systemRefused(OSStatus)
    }

    public init() {}

    public func currentInputDeviceIdentifier() -> String? {
        defaultInputDeviceID().flatMap(uniqueIdentifier(of:))
    }

    public func selectInputDevice(identifier: String) throws {
        guard var deviceID = deviceIDs().first(where: { uniqueIdentifier(of: $0) == identifier })
        else { throw RouterError.deviceNotFound }
        var address = Self.address(kAudioHardwarePropertyDefaultInputDevice)
        let status = AudioObjectSetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            UInt32(MemoryLayout<AudioDeviceID>.size),
            &deviceID
        )
        guard status == noErr else { throw RouterError.systemRefused(status) }
    }

    private static func address(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        .init(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
    }

    private func defaultInputDeviceID() -> AudioDeviceID? {
        var address = Self.address(kAudioHardwarePropertyDefaultInputDevice)
        var deviceID = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceID)
        guard status == noErr, deviceID != 0 else { return nil }
        return deviceID
    }

    private func deviceIDs() -> [AudioDeviceID] {
        var address = Self.address(kAudioHardwarePropertyDevices)
        var size = UInt32(0)
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr,
            size > 0
        else { return [] }
        var identifiers = [AudioDeviceID](
            repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &identifiers) == noErr
        else { return [] }
        return identifiers
    }

    private func uniqueIdentifier(of device: AudioDeviceID) -> String? {
        var address = Self.address(kAudioDevicePropertyDeviceUID)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value)
        guard status == noErr, let value else { return nil }
        return value.takeRetainedValue() as String
    }
}

public struct SMAppServiceLaunchAtLogin: LaunchAtLoginControlling {
    public init() {}

    public func isEnabled() -> Bool {
        SMAppService.mainApp.status == .enabled
    }

    public func setEnabled(_ enabled: Bool) throws {
        if enabled {
            try SMAppService.mainApp.register()
        } else {
            try SMAppService.mainApp.unregister()
        }
    }
}

public struct WorkspaceLinkOpener: ExternalLinkOpening {
    public init() {}

    public func open(_ url: URL) {
        NSWorkspace.shared.open(url)
    }
}

/// Fetches the signed manifest for one explicit Model Pack action through ModelRuntime's resumable
/// downloader, which is the only component in Poptart allowed to reach the network.
public struct DownloadedModelPackManifestSource: ModelPackManifestSourcing {
    public enum SourceError: Error, Equatable, Sendable {
        case unsupportedVersion(String)
        case unreadableManifest
    }

    /// A signed manifest is a few kilobytes; a larger response is refused before it is read.
    public static let maximumManifestBytes: Int64 = 1_048_576

    private let baseURL: URL
    private let downloader: any ResumableArtifactDownloading
    private let stagingDirectory: URL

    public init(
        baseURL: URL = PoptartRelease.modelPackManifestBaseURL,
        downloader: any ResumableArtifactDownloading,
        stagingDirectory: URL = FileManager.default.temporaryDirectory
    ) {
        self.baseURL = baseURL
        self.downloader = downloader
        self.stagingDirectory = stagingDirectory
    }

    public func signedManifest(for request: ModelPackManifestRequest) async throws -> Data {
        let name: String
        if let version = request.version {
            guard !version.isEmpty, version.unicodeScalars.allSatisfy({
                CharacterSet.alphanumerics.contains($0) || $0 == "." || $0 == "-" || $0 == "_"
            }) else { throw SourceError.unsupportedVersion(version) }
            name = "\(version).json"
        } else {
            name = "latest.json"
        }
        let destination = stagingDirectory.appendingPathComponent(
            "poptart-manifest-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: destination) }
        _ = try await downloader.download(
            .init(
                source: baseURL.appendingPathComponent(name),
                destination: destination,
                resumeOffset: 0,
                expectedSize: Self.maximumManifestBytes
            ))
        guard let data = try? Data(contentsOf: destination), !data.isEmpty else {
            throw SourceError.unreadableManifest
        }
        return data
    }
}

/// Stands in when the build has no way to fetch a manifest. It reaches no network and reports the
/// missing signing key, which is the same thing that stops the install itself.
public struct UnavailableModelPackManifestSource: ModelPackManifestSourcing {
    public init() {}

    public func signedManifest(for request: ModelPackManifestRequest) async throws -> Data {
        throw ModelPackTrustError.signingKeyMissing
    }
}

extension ModelPackInstaller: ModelPackInstalling {}

/// Describes a signed manifest only after its signature verifies against the app-embedded key.
public struct VerifiedModelPackOffers: ModelPackOfferDescribing {
    private let publicKey: @Sendable () throws -> Data

    public init(publicKey: @escaping @Sendable () throws -> Data = {
        try ModelPackTrust.embeddedPublicKey()
    }) {
        self.publicKey = publicKey
    }

    public func describe(signedManifest: Data) throws -> ModelPackOffer {
        let manifest = try ModelPackManifestVerifier(publicKeyData: publicKey())
            .verify(signedManifest)
        return .init(
            identity: manifest.identity,
            version: manifest.version,
            downloadBytes: manifest.artifacts.reduce(0) { $0 + $1.byteSize },
            licenses: manifest.artifacts.map {
                .init(role: $0.role.rawValue, name: $0.license.name, url: $0.license.url)
            },
            signedManifest: signedManifest
        )
    }
}

/// Stands in when the build carries no Model Pack signing key. Every action reports the missing key
/// instead of installing something Poptart cannot verify.
public struct UnavailableModelPackInstaller: ModelPackInstalling {
    public init() {}

    public func activePack() async -> InstalledModelPack? { nil }

    @discardableResult
    public func perform(
        _ action: ExplicitModelPackAction,
        signedManifest: Data
    ) async throws -> InstalledModelPack {
        throw ModelPackTrustError.signingKeyMissing
    }
}

public struct LocatedModelPackProvider: ActiveModelPackProviding {
    private let modelRuntimeDirectory: URL

    public init(modelRuntimeDirectory: URL) {
        self.modelRuntimeDirectory = modelRuntimeDirectory
    }

    public func activePack() async throws -> ActiveApplicationModelPack? {
        try ApplicationModelPackLocator.activePack(in: modelRuntimeDirectory)
    }
}

public struct FileSystemModelPackStorage: ModelPackStorageMeasuring {
    public init() {}

    public func byteSize(of directory: URL) -> Int64 {
        guard let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey]
        ) else { return 0 }
        var total: Int64 = 0
        for case let url as URL in enumerator {
            let values = try? url.resourceValues(
                forKeys: [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey])
            let size = values?.totalFileAllocatedSize ?? values?.fileAllocatedSize ?? 0
            total += Int64(size)
        }
        return total
    }
}

/// Loads a staged pack exactly the way the runtime will before the installer activates it.
public struct LocalModelPackSmokeTest: ModelPackSmokeTesting {
    public enum SmokeTestError: Error, Equatable, Sendable {
        case artifactMissing(String)
    }

    public init() {}

    public func validate(packAt directory: URL, manifest: ModelPackManifest) async throws {
        for artifact in manifest.artifacts {
            let url = directory.appendingPathComponent(artifact.relativePath)
            guard FileManager.default.fileExists(atPath: url.path) else {
                throw SmokeTestError.artifactMissing(artifact.relativePath)
            }
        }
        let layout = ApplicationModelPackLayout(root: directory)
        let recognition = try RecognitionService(
            modelLayout: .init(
                unifiedModelDirectory: layout.unifiedRecognition,
                ctcModelDirectory: layout.optionalCTC
            ),
            onEvent: { _ in }
        )
        try await recognition.prepare()
        let cleanup = try MLXCleanupModel(modelDirectory: layout.cleanup)
        try await cleanup.prepare()
        await cleanup.unload()
    }
}

/// Reads the encrypted Dictation Records for the history surface.
public struct HistoryStoreRecords: DictationRecordStoring, RecentDictationProbing {
    private let store: HistoryStore

    public init(store: HistoryStore) {
        self.store = store
    }

    public func records() async throws -> [Persistence.DictationRecord] {
        try await store.records()
    }

    public func delete(_ id: UUID) async throws {
        try await store.delete(id)
    }

    public func clearHistory() async throws {
        try await store.clearHistory()
    }

    public func hasDictation(since instant: Date) async -> Bool {
        let records = (try? await store.records()) ?? []
        return records.contains { $0.createdAt >= instant }
    }
}

public struct PersonalVocabularyStoreEditor: PersonalVocabularyEditing {
    private let store: PersonalVocabularyStore

    public init(store: PersonalVocabularyStore) {
        self.store = store
    }

    public func terms() async throws -> [String] {
        try await store.terms()
    }

    public func replaceTerms(_ terms: [String]) async throws {
        try await store.replaceTerms(terms)
    }
}

public struct PasteboardTextCopier: TextCopying {
    private let pasteboard: any PasteboardClient

    public init(pasteboard: any PasteboardClient = SystemPasteboardClient()) {
        self.pasteboard = pasteboard
    }

    public func copy(_ text: String) async -> Bool {
        await pasteboard.writeText(text) != nil
    }
}

/// Confirms Poptart can turn speech into text with the network switched off: the installed pack
/// still verifies against its manifest, and the permissions the earlier onboarding steps granted
/// are in place. It makes no network request, and it does not require Input Monitoring, which the
/// next step grants.
public struct InstalledPackOfflineReadiness: OfflineReadinessChecking {
    private let modelRuntimeDirectory: URL
    private let permissions: @Sendable () -> PermissionSnapshot

    public init(
        modelRuntimeDirectory: URL,
        permissions: @escaping @Sendable () -> PermissionSnapshot
    ) {
        self.modelRuntimeDirectory = modelRuntimeDirectory
        self.permissions = permissions
    }

    public func check() async -> OfflineReadinessReport {
        let snapshot = permissions()
        do {
            let pack = try ApplicationModelPackLocator.activePack(in: modelRuntimeDirectory)
            guard pack != nil else {
                return .init(
                    modelPackVerified: false,
                    permissions: snapshot,
                    failureDescription: "No Model Pack is installed yet."
                )
            }
            guard snapshot.microphone.isGranted, snapshot.accessibility.isGranted else {
                return .init(
                    modelPackVerified: true,
                    permissions: snapshot,
                    failureDescription:
                        "Poptart still needs the microphone and Accessibility before it can dictate."
                )
            }
            return .init(modelPackVerified: true, permissions: snapshot, failureDescription: nil)
        } catch {
            return .init(
                modelPackVerified: false,
                permissions: snapshot,
                failureDescription:
                    "The installed Model Pack no longer matches its manifest. Use Repair Model Pack."
            )
        }
    }
}
