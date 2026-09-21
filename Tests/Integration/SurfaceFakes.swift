import Foundation
import ModelRuntime
import Persistence
import SystemIntegration

@testable import PoptartApplication

// Fakes for every surface boundary. No test prompts macOS, touches the network, waits on the wall
// clock, or reads a real person's encrypted data.

/// A lock-guarded value so a fake can be read from a test and written from a model.
final class Box<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: Value

    init(_ value: Value) { storage = value }

    var value: Value {
        get { lock.withLock { storage } }
        set { lock.withLock { storage = newValue } }
    }

    func mutate(_ change: (inout Value) -> Void) { lock.withLock { change(&storage) } }
}

actor StubSettingsStore: AppSettingsStoring {
    private(set) var stored: AppSettings
    var writeFailure: (any Error)?
    private(set) var writeCount = 0

    init(_ stored: AppSettings = .defaults) { self.stored = stored }

    func settings() -> AppSettings { stored }

    func setShortcutBinding(_ binding: ShortcutBinding) throws {
        try write { $0.shortcutBinding = binding }
    }

    func setMicrophoneDeviceIdentifier(_ identifier: String?) throws {
        try write { $0.microphoneDeviceIdentifier = identifier }
    }

    func setOnboardingProgress(_ progress: OnboardingProgress) throws {
        try write { $0.onboarding = progress }
    }

    func failWrites(with error: any Error) { writeFailure = error }

    private func write(_ change: (inout AppSettings) -> Void) throws {
        if let writeFailure { throw writeFailure }
        change(&stored)
        writeCount += 1
    }
}

struct StubError: Error, Equatable {
    let reason: String
    init(_ reason: String = "stub") { self.reason = reason }
}

final class StubMicrophonePermission: MicrophonePermissionControlling, @unchecked Sendable {
    let current: Box<PermissionState>
    let grantsOnRequest: Bool
    let requests = Box(0)

    init(_ state: PermissionState = .undetermined, grantsOnRequest: Bool = true) {
        current = Box(state)
        self.grantsOnRequest = grantsOnRequest
    }

    func state() -> PermissionState { current.value }

    @discardableResult
    func request() async -> Bool {
        requests.mutate { $0 += 1 }
        current.value = grantsOnRequest ? .granted : .denied
        return grantsOnRequest
    }
}

final class StubAccessibilityPermission: AccessibilityPermission, @unchecked Sendable {
    let granted: Box<Bool>
    let grantsOnRequest: Bool
    let requests = Box(0)

    init(granted: Bool = false, grantsOnRequest: Bool = true) {
        self.granted = Box(granted)
        self.grantsOnRequest = grantsOnRequest
    }

    func isGranted() -> Bool { granted.value }

    func request() -> Bool {
        requests.mutate { $0 += 1 }
        granted.value = grantsOnRequest
        return grantsOnRequest
    }
}

final class StubKeyboardPermission: KeyboardMonitoringPermission, @unchecked Sendable {
    let granted: Box<Bool>
    let grantsOnRequest: Bool
    let requests = Box(0)

    init(granted: Bool = false, grantsOnRequest: Bool = true) {
        self.granted = Box(granted)
        self.grantsOnRequest = grantsOnRequest
    }

    func isGranted() -> Bool { granted.value }

    func request() -> Bool {
        requests.mutate { $0 += 1 }
        granted.value = grantsOnRequest
        return grantsOnRequest
    }
}

actor StubModelPackProvider: ActiveModelPackProviding {
    private var pack: ActiveApplicationModelPack?
    private var failure: (any Error)?
    private(set) var calls = 0

    init(pack: ActiveApplicationModelPack? = nil, failure: (any Error)? = nil) {
        self.pack = pack
        self.failure = failure
    }

    func activePack() throws -> ActiveApplicationModelPack? {
        calls += 1
        if let failure { throw failure }
        return pack
    }

    func install(_ pack: ActiveApplicationModelPack?) {
        self.pack = pack
        failure = nil
    }
}

actor StubManifestSource: ModelPackManifestSourcing {
    private(set) var requests: [ModelPackManifestRequest] = []
    private var payload: Data
    private var failure: (any Error)?

    init(payload: Data = Data("signed".utf8), failure: (any Error)? = nil) {
        self.payload = payload
        self.failure = failure
    }

    func signedManifest(for request: ModelPackManifestRequest) throws -> Data {
        requests.append(request)
        if let failure { throw failure }
        return payload
    }

    func fail(with error: any Error) { failure = error }
}

struct StubOfferDescriber: ModelPackOfferDescribing {
    var offer: ModelPackOffer
    var failure: StubError?

    init(offer: ModelPackOffer = .stub(), failure: StubError? = nil) {
        self.offer = offer
        self.failure = failure
    }

    func describe(signedManifest: Data) throws -> ModelPackOffer {
        if let failure { throw failure }
        return offer
    }
}

actor StubInstaller: ModelPackInstalling {
    private(set) var performed: [(action: ExplicitModelPackAction, manifest: Data)] = []
    private var installed: InstalledModelPack?
    private var failure: (any Error)?

    init(installed: InstalledModelPack? = nil, failure: (any Error)? = nil) {
        self.installed = installed
        self.failure = failure
    }

    func activePack() -> InstalledModelPack? { installed }

    @discardableResult
    func perform(
        _ action: ExplicitModelPackAction,
        signedManifest: Data
    ) async throws -> InstalledModelPack {
        performed.append((action, signedManifest))
        if let failure { throw failure }
        let pack = installed ?? .stub()
        installed = pack
        return pack
    }

    func result(_ pack: InstalledModelPack) { installed = pack }
    func fail(with error: any Error) { failure = error }
}

actor StubReadinessCheck: OfflineReadinessChecking {
    private var report: OfflineReadinessReport
    private(set) var checks = 0

    init(report: OfflineReadinessReport) { self.report = report }

    func check() -> OfflineReadinessReport {
        checks += 1
        return report
    }

    func set(_ report: OfflineReadinessReport) { self.report = report }
}

actor StubDictationProbe: RecentDictationProbing {
    private var completions: [Date]
    private(set) var probes: [Date] = []

    init(completions: [Date] = []) { self.completions = completions }

    func hasDictation(since instant: Date) -> Bool {
        probes.append(instant)
        return completions.contains { $0 >= instant }
    }

    func complete(at instant: Date) { completions.append(instant) }
}

struct StubDeviceEnumerator: MicrophoneDeviceEnumerating {
    var available: [MicrophoneDevice]

    func devices() -> [MicrophoneDevice] { available }
}

final class StubMicrophoneRouter: MicrophoneRouting, @unchecked Sendable {
    let current: Box<String?>
    let unavailable: Box<Set<String>>
    let selections = Box<[String]>([])

    init(current: String? = nil, unavailable: Set<String> = []) {
        self.current = Box(current)
        self.unavailable = Box(unavailable)
    }

    func currentInputDeviceIdentifier() -> String? { current.value }

    func selectInputDevice(identifier: String) throws {
        selections.mutate { $0.append(identifier) }
        guard !unavailable.value.contains(identifier) else { throw StubError("no such device") }
        current.value = identifier
    }
}

final class StubLaunchAtLogin: LaunchAtLoginControlling, @unchecked Sendable {
    let enabled: Box<Bool>
    let refuses: Bool

    init(enabled: Bool = false, refuses: Bool = false) {
        self.enabled = Box(enabled)
        self.refuses = refuses
    }

    func isEnabled() -> Bool { enabled.value }

    func setEnabled(_ newValue: Bool) throws {
        guard !refuses else { throw StubError("macOS refused") }
        enabled.value = newValue
    }
}

struct StubStorageMeasure: ModelPackStorageMeasuring {
    var bytes: Int64

    func byteSize(of directory: URL) -> Int64 { bytes }
}

actor StubVocabulary: PersonalVocabularyEditing {
    private(set) var stored: [String]
    private var readFailure: (any Error)?
    private var writeFailure: (any Error)?

    init(
        stored: [String] = [],
        readFailure: (any Error)? = nil,
        writeFailure: (any Error)? = nil
    ) {
        self.stored = stored
        self.readFailure = readFailure
        self.writeFailure = writeFailure
    }

    func terms() throws -> [String] {
        if let readFailure { throw readFailure }
        return stored
    }

    func replaceTerms(_ terms: [String]) throws {
        if let writeFailure { throw writeFailure }
        stored = terms
    }
}

actor StubRecordStore: DictationRecordStoring {
    private(set) var stored: [Persistence.DictationRecord]
    private var readFailure: (any Error)?
    private var mutationFailure: (any Error)?
    private(set) var cleared = 0

    init(
        stored: [Persistence.DictationRecord] = [],
        readFailure: (any Error)? = nil,
        mutationFailure: (any Error)? = nil
    ) {
        self.stored = stored
        self.readFailure = readFailure
        self.mutationFailure = mutationFailure
    }

    func records() throws -> [Persistence.DictationRecord] {
        if let readFailure { throw readFailure }
        return stored
    }

    func delete(_ id: UUID) throws {
        if let mutationFailure { throw mutationFailure }
        stored.removeAll { $0.id == id }
    }

    func clearHistory() throws {
        if let mutationFailure { throw mutationFailure }
        cleared += 1
        stored = []
    }
}

actor StubClipboard: TextCopying {
    private(set) var copied: [String] = []
    private var accepts: Bool

    init(accepts: Bool = true) { self.accepts = accepts }

    func copy(_ text: String) -> Bool {
        copied.append(text)
        return accepts
    }

    func refuse() { accepts = false }
}

// MARK: - Value helpers

extension ModelPackOffer {
    static func stub(
        version: String = "1.2.0",
        downloadBytes: Int64 = 1_200_000_000,
        signedManifest: Data = Data("signed".utf8)
    ) -> ModelPackOffer {
        .init(
            identity: "poptart-model-pack",
            version: version,
            downloadBytes: downloadBytes,
            licenses: [
                .init(
                    role: "recognition",
                    name: "Apache-2.0",
                    url: URL(string: "https://www.apache.org/licenses/LICENSE-2.0")!
                )
            ],
            signedManifest: signedManifest
        )
    }
}

func stubManifest(
    version: String = "1.2.0",
    cleanupTokenCeiling: Int = 768
) -> ModelPackManifest {
    let license = ModelLicense(
        name: "Apache-2.0",
        url: URL(string: "https://www.apache.org/licenses/LICENSE-2.0")!
    )
    return try! ModelPackManifest(
        identity: "poptart-model-pack",
        version: version,
        minimumApplicationVersion: "0.1.0",
        maximumApplicationVersion: "9.9.9",
        cleanupTokenCeiling: cleanupTokenCeiling,
        artifacts: [
            .init(
                role: .recognition,
                url: URL(string: "https://downloads.example.com/recognition")!,
                relativePath: "recognition/unified/model.bin",
                byteSize: 900_000_000,
                sha256: String(repeating: "a", count: 64),
                license: license
            ),
            .init(
                role: .recognition,
                url: URL(string: "https://downloads.example.com/recognition-config")!,
                relativePath: "recognition/unified/config.json",
                byteSize: 1_000,
                sha256: String(repeating: "c", count: 64),
                license: license
            ),
            .init(
                role: .cleanup,
                url: URL(string: "https://downloads.example.com/cleanup")!,
                relativePath: "cleanup/model.safetensors",
                byteSize: 300_000_000,
                sha256: String(repeating: "b", count: 64),
                license: license
            ),
        ]
    )
}

extension InstalledModelPack {
    static func stub(
        version: String = "1.2.0",
        cleanupTokenCeiling: Int = 768,
        directory: URL = URL(fileURLWithPath: "/tmp/poptart-pack", isDirectory: true)
    ) -> InstalledModelPack {
        .init(
            directory: directory,
            manifest: stubManifest(version: version, cleanupTokenCeiling: cleanupTokenCeiling)
        )
    }
}

extension ActiveApplicationModelPack {
    static func stub(
        version: String = "1.2.0",
        cleanupTokenCeiling: Int? = 768,
        root: URL = URL(fileURLWithPath: "/tmp/poptart-pack", isDirectory: true),
        origin: ModelPackOrigin = .installed
    ) -> ActiveApplicationModelPack {
        .init(
            layout: .init(root: root),
            cleanupTokenCeiling: cleanupTokenCeiling,
            version: version,
            manifest: stubManifest(
                version: version,
                cleanupTokenCeiling: cleanupTokenCeiling ?? 768
            ),
            origin: origin
        )
    }
}

func stubRecord(
    id: UUID = UUID(),
    createdAt: Date = Date(timeIntervalSince1970: 1_000),
    rawTranscript: String = "hello world",
    deliveredText: String = "Hello, world.",
    destination: String = "com.example.Editor",
    cleanupChangedText: Bool = true,
    outcome: Persistence.DictationOutcome = .cleaned,
    timings: DictationTimings = .init(
        recognitionMilliseconds: 120,
        cleanupMilliseconds: 400,
        deliveryMilliseconds: 20
    )
) -> Persistence.DictationRecord {
    .init(
        id: id,
        createdAt: createdAt,
        rawTranscript: rawTranscript,
        deliveredText: deliveredText,
        destinationApplication: destination,
        cleanupChangedText: cleanupChangedText,
        outcome: outcome,
        timings: timings
    )
}
