import Foundation
import ModelRuntime
import Persistence

// The boundaries the onboarding, settings, and history surfaces talk to. Every one of them is a
// protocol so the surfaces stay decidable in tests without prompting macOS, touching the network,
// or reading a person's encrypted data.

/// One spelling of a byte count for every surface that shows a download or a storage size.
public enum ByteSize {
    public static func description(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}

public enum PermissionState: String, Equatable, Sendable {
    case granted
    case denied
    case undetermined

    public var isGranted: Bool { self == .granted }
}

public struct PermissionSnapshot: Equatable, Sendable {
    public var microphone: PermissionState
    public var accessibility: PermissionState
    public var keyboardMonitoring: PermissionState

    public init(
        microphone: PermissionState,
        accessibility: PermissionState,
        keyboardMonitoring: PermissionState
    ) {
        self.microphone = microphone
        self.accessibility = accessibility
        self.keyboardMonitoring = keyboardMonitoring
    }

    /// What Poptart knows before it has asked macOS anything.
    public static let unknown = PermissionSnapshot(
        microphone: .undetermined,
        accessibility: .denied,
        keyboardMonitoring: .denied
    )

    public var allGranted: Bool {
        microphone.isGranted && accessibility.isGranted && keyboardMonitoring.isGranted
    }
}

public protocol MicrophonePermissionControlling: Sendable {
    func state() -> PermissionState
    @discardableResult
    func request() async -> Bool
}

public struct MicrophoneDevice: Equatable, Sendable, Identifiable {
    public let id: String
    public let name: String

    public init(id: String, name: String) {
        self.id = id
        self.name = name
    }
}

public protocol MicrophoneDeviceEnumerating: Sendable {
    func devices() -> [MicrophoneDevice]
}

/// Points audio capture at the chosen microphone. Recognition records from the Mac's input device,
/// so choosing a microphone in Poptart selects that input device.
public protocol MicrophoneRouting: Sendable {
    func currentInputDeviceIdentifier() -> String?
    func selectInputDevice(identifier: String) throws
}

public protocol LaunchAtLoginControlling: Sendable {
    func isEnabled() -> Bool
    func setEnabled(_ enabled: Bool) throws
}

public struct ModelPackLicenseSummary: Equatable, Sendable, Identifiable {
    public let role: String
    public let name: String
    public let url: URL

    public var id: String { "\(role)-\(name)-\(url.absoluteString)" }

    public init(role: String, name: String, url: URL) {
        self.role = role
        self.name = name
        self.url = url
    }
}

/// What a signed manifest offers before anyone downloads anything: identity, version, total
/// download size, and the licenses the artifacts carry.
public struct ModelPackOffer: Equatable, Sendable {
    public let identity: String
    public let version: String
    public let downloadBytes: Int64
    public let licenses: [ModelPackLicenseSummary]
    public let signedManifest: Data

    public init(
        identity: String,
        version: String,
        downloadBytes: Int64,
        licenses: [ModelPackLicenseSummary],
        signedManifest: Data
    ) {
        self.identity = identity
        self.version = version
        self.downloadBytes = downloadBytes
        self.licenses = licenses
        self.signedManifest = signedManifest
    }
}

public struct ModelPackManifestRequest: Equatable, Sendable {
    public let action: ExplicitModelPackAction
    /// The exact version to describe, so a repair reinstalls what is installed; nil asks for the
    /// latest published pack.
    public let version: String?

    public init(action: ExplicitModelPackAction, version: String?) {
        self.action = action
        self.version = version
    }
}

/// Fetches the signed manifest for one explicit Model Pack action. Model Pack network access
/// stays inside an action a person started; application updates use their own explicit action.
public protocol ModelPackManifestSourcing: Sendable {
    func signedManifest(for request: ModelPackManifestRequest) async throws -> Data
}

/// Verifies a signed manifest with the app-embedded public key and describes what it offers, so no
/// surface ever shows a size or a license it has not verified.
public protocol ModelPackOfferDescribing: Sendable {
    func describe(signedManifest: Data) throws -> ModelPackOffer
}

/// Explains a failed Model Pack action in terms a person can act on, naming no file or URL.
public enum ModelPackFailureMessage {
    public static func text(for error: any Error) -> String {
        if error is ModelPackTrustError {
            return "This build carries no Model Pack signing key, so it cannot verify a download."
        }
        guard let error = error as? ModelPackError else {
            return "The Model Pack action did not finish. Use Repair Model Pack to try again."
        }
        switch error {
        case .invalidManifestSignature, .invalidManifest, .invalidPublicKey:
            return "The Model Pack description did not verify. Poptart installed nothing."
        case .invalidCleanupTokenCeiling:
            return "The Model Pack ships no measured Cleanup budget. Poptart installed nothing."
        case .artifactHashMismatch, .artifactSizeMismatch, .artifactInventoryMismatch:
            return "A downloaded file did not match its published hash. Poptart installed nothing."
        case .smokeTestFailed:
            return "The downloaded Model Pack did not load. The previous pack is still active."
        case .downloadFailed, .incompleteDownload, .downloadExceededExpectedSize:
            return "The download did not finish. Start it again to resume where it stopped."
        case .incompatibleApplicationVersion:
            return "That Model Pack does not support this version of Poptart."
        case .downgradeNotAllowed:
            return "That Model Pack is older than the one already installed."
        case .installationInProgress:
            return "A Model Pack installation is already in progress."
        case .invalidActiveState, .fileSystemFailure:
            return "The installed Model Pack no longer verifies. Use Repair Model Pack."
        case .unrecoverableActiveState:
            return "Model Pack verification data is damaged. Automatic repair is unavailable."
        }
    }
}

public protocol ModelPackInstalling: Sendable {
    func activePack() async -> InstalledModelPack?
    @discardableResult
    func perform(
        _ action: ExplicitModelPackAction,
        signedManifest: Data
    ) async throws -> InstalledModelPack
}

public protocol ModelPackStorageMeasuring: Sendable {
    func byteSize(of directory: URL) -> Int64
}

/// Reports the pack the runtime would start with. Throwing means the activation record or its
/// artifacts no longer verify, which is a repairable state rather than an empty one.
public protocol ActiveModelPackProviding: Sendable {
    func activePack() async throws -> ActiveApplicationModelPack?
}

public struct OfflineReadinessReport: Equatable, Sendable {
    public let modelPackVerified: Bool
    public let permissions: PermissionSnapshot
    /// A human explanation when the check failed; nil when everything needed offline is present.
    public let failureDescription: String?

    public init(
        modelPackVerified: Bool,
        permissions: PermissionSnapshot,
        failureDescription: String?
    ) {
        self.modelPackVerified = modelPackVerified
        self.permissions = permissions
        self.failureDescription = failureDescription
    }

    /// Offline readiness asks whether the words can be recognized and delivered with the network
    /// switched off: a verified Model Pack, the microphone, and Accessibility. Input Monitoring is
    /// what the shortcut-test step exists to grant, so it is reported here but never blocks this
    /// check; onboarding completion still requires it.
    public var isReady: Bool {
        modelPackVerified && permissions.microphone.isGranted && permissions.accessibility.isGranted
    }
}

/// Confirms Poptart can dictate with the network switched off: the installed pack verifies against
/// its manifest and every permission is granted. It performs no network request.
public protocol OfflineReadinessChecking: Sendable {
    func check() async -> OfflineReadinessReport
}

public protocol DictationRecordStoring: Sendable {
    func records() async throws -> [Persistence.DictationRecord]
    func delete(_ id: UUID) async throws
    func clearHistory() async throws
}

public protocol PersonalVocabularyEditing: Sendable {
    func terms() async throws -> [String]
    func replaceTerms(_ terms: [String]) async throws
}

/// Answers whether a Dictation finished after a given moment, which is how the onboarding first
/// Dictation test confirms success without reading any transcript text.
public protocol RecentDictationProbing: Sendable {
    func hasDictation(since instant: Date) async -> Bool
}

public protocol TextCopying: Sendable {
    func copy(_ text: String) async -> Bool
}
