import Foundation
import ModelRuntime
import Observation
import SystemIntegration

public enum OnboardingStep: String, Codable, CaseIterable, Sendable {
    case explanation
    case microphonePermission
    case accessibilityPermission
    case modelPack
    case offlineReadiness
    case shortcutTest
    case firstDictation

    public var title: String {
        switch self {
        case .explanation: "What Poptart does"
        case .microphonePermission: "Microphone"
        case .accessibilityPermission: "Accessibility"
        case .modelPack: "Model Pack"
        case .offlineReadiness: "Offline readiness"
        case .shortcutTest: "Shortcut test"
        case .firstDictation: "First Dictation"
        }
    }
}

/// What onboarding remembers between launches. Permissions and the active Model Pack are read from
/// the system on every launch instead, so only the person's own answers are stored here.
public struct OnboardingProgress: Codable, Equatable, Sendable {
    public var explanationAcknowledged: Bool
    public var offlineReadinessConfirmed: Bool
    public var shortcutTestPassed: Bool
    public var firstDictationCompleted: Bool

    public static let initial = OnboardingProgress(
        explanationAcknowledged: false,
        offlineReadinessConfirmed: false,
        shortcutTestPassed: false,
        firstDictationCompleted: false
    )

    public init(
        explanationAcknowledged: Bool,
        offlineReadinessConfirmed: Bool,
        shortcutTestPassed: Bool,
        firstDictationCompleted: Bool
    ) {
        self.explanationAcknowledged = explanationAcknowledged
        self.offlineReadinessConfirmed = offlineReadinessConfirmed
        self.shortcutTestPassed = shortcutTestPassed
        self.firstDictationCompleted = firstDictationCompleted
    }

    /// A stored file written by an older build may be missing answers; a missing answer means the
    /// step has not been done rather than a broken file.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        func answer(_ key: CodingKeys) -> Bool {
            ((try? container.decodeIfPresent(Bool.self, forKey: key)) ?? nil) ?? false
        }
        self.explanationAcknowledged = answer(.explanationAcknowledged)
        self.offlineReadinessConfirmed = answer(.offlineReadinessConfirmed)
        self.shortcutTestPassed = answer(.shortcutTestPassed)
        self.firstDictationCompleted = answer(.firstDictationCompleted)
    }
}

/// Everything the system must confirm; none of it is remembered across launches.
public struct OnboardingRequirements: Equatable, Sendable {
    public var permissions: PermissionSnapshot
    public var hasActiveModelPack: Bool

    public init(permissions: PermissionSnapshot, hasActiveModelPack: Bool) {
        self.permissions = permissions
        self.hasActiveModelPack = hasActiveModelPack
    }

    public static let unknown = OnboardingRequirements(
        permissions: .unknown, hasActiveModelPack: false)
}

public enum OnboardingBlocker: String, Equatable, Sendable, CaseIterable {
    case microphonePermission
    case accessibilityPermission
    case keyboardMonitoringPermission
    case activeModelPack
    case shortcutTest

    public var description: String {
        switch self {
        case .microphonePermission: "Microphone access is not granted."
        case .accessibilityPermission: "Accessibility access is not granted."
        case .keyboardMonitoringPermission: "Input Monitoring is not granted."
        case .activeModelPack: "No verified Model Pack is active."
        case .shortcutTest: "The shortcut test has not succeeded."
        }
    }

    /// The step that asks for this, so a surface showing one step can tell whether a blocker is
    /// its own business or something a later step will handle.
    public var step: OnboardingStep {
        switch self {
        case .microphonePermission: .microphonePermission
        case .accessibilityPermission: .accessibilityPermission
        case .keyboardMonitoringPermission: .shortcutTest
        case .activeModelPack: .modelPack
        case .shortcutTest: .shortcutTest
        }
    }
}

/// The rules that decide where onboarding resumes and whether it may report completion.
public enum OnboardingPolicy {
    /// The first step whose work is not done. Resuming means starting here.
    public static func currentStep(
        progress: OnboardingProgress,
        requirements: OnboardingRequirements
    ) -> OnboardingStep {
        if !progress.explanationAcknowledged { return .explanation }
        if !requirements.permissions.microphone.isGranted { return .microphonePermission }
        if !requirements.permissions.accessibility.isGranted { return .accessibilityPermission }
        if !requirements.hasActiveModelPack { return .modelPack }
        if !progress.offlineReadinessConfirmed { return .offlineReadiness }
        if !requirements.permissions.keyboardMonitoring.isGranted || !progress.shortcutTestPassed {
            return .shortcutTest
        }
        return .firstDictation
    }

    /// The prerequisites SPEC requires before onboarding may report completion: permissions, the
    /// active Model Pack, and a succeeding shortcut test.
    public static func blockers(
        progress: OnboardingProgress,
        requirements: OnboardingRequirements
    ) -> [OnboardingBlocker] {
        var blockers: [OnboardingBlocker] = []
        if !requirements.permissions.microphone.isGranted { blockers.append(.microphonePermission) }
        if !requirements.permissions.accessibility.isGranted {
            blockers.append(.accessibilityPermission)
        }
        if !requirements.permissions.keyboardMonitoring.isGranted {
            blockers.append(.keyboardMonitoringPermission)
        }
        if !requirements.hasActiveModelPack { blockers.append(.activeModelPack) }
        if !progress.shortcutTestPassed { blockers.append(.shortcutTest) }
        return blockers
    }

    public static func isComplete(
        progress: OnboardingProgress,
        requirements: OnboardingRequirements
    ) -> Bool {
        blockers(progress: progress, requirements: requirements).isEmpty
            && progress.explanationAcknowledged
            && progress.offlineReadinessConfirmed
            && progress.firstDictationCompleted
    }
}

/// How far the explicit Model Pack download has got. Nothing here starts on its own.
public enum ModelPackInstallState: Equatable, Sendable {
    case idle
    case describing
    case offered(ModelPackOffer)
    case installing(ModelPackOffer)
    case installed(version: String)
    case failed(String)

    public var offer: ModelPackOffer? {
        switch self {
        case .offered(let offer), .installing(let offer): offer
        default: nil
        }
    }

    public var isWorking: Bool {
        switch self {
        case .describing, .installing: true
        default: false
        }
    }

    public var statusText: String? {
        switch self {
        case .idle:
            nil
        case .describing:
            "Asking the release channel what the Model Pack contains…"
        case .offered(let offer):
            "Model Pack \(offer.version) — \(ByteSize.description(offer.downloadBytes)) to download."
        case .installing(let offer):
            "Downloading and verifying Model Pack \(offer.version)…"
        case .installed(let version):
            "Model Pack \(version) is installed and verified."
        case .failed(let message):
            message
        }
    }
}

@MainActor
@Observable
public final class OnboardingModel {
    public private(set) var progress: OnboardingProgress = .initial
    public private(set) var requirements: OnboardingRequirements = .unknown
    public private(set) var installState: ModelPackInstallState = .idle
    public private(set) var readinessReport: OfflineReadinessReport?
    public private(set) var firstDictationMessage: String?
    public private(set) var shortcutTestMessage: String?

    public let shortcut: ShortcutBindingModel

    private let settings: any AppSettingsStoring
    private let microphonePermission: any MicrophonePermissionControlling
    private let accessibilityPermission: any AccessibilityPermission
    private let keyboardPermission: any KeyboardMonitoringPermission
    private let modelPacks: any ActiveModelPackProviding
    private let manifests: any ModelPackManifestSourcing
    private let offers: any ModelPackOfferDescribing
    private let installer: any ModelPackInstalling
    private let readiness: any OfflineReadinessChecking
    private let dictationProbe: any RecentDictationProbing
    private let now: @Sendable () -> Date
    private var shortcutPressSeen = false
    private var firstDictationStartedAt: Date?
    private var viewedStep: OnboardingStep?

    public init(
        shortcut: ShortcutBindingModel,
        settings: any AppSettingsStoring,
        microphonePermission: any MicrophonePermissionControlling,
        accessibilityPermission: any AccessibilityPermission,
        keyboardPermission: any KeyboardMonitoringPermission,
        modelPacks: any ActiveModelPackProviding,
        manifests: any ModelPackManifestSourcing,
        offers: any ModelPackOfferDescribing,
        installer: any ModelPackInstalling,
        readiness: any OfflineReadinessChecking,
        dictationProbe: any RecentDictationProbing,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.shortcut = shortcut
        self.settings = settings
        self.microphonePermission = microphonePermission
        self.accessibilityPermission = accessibilityPermission
        self.keyboardPermission = keyboardPermission
        self.modelPacks = modelPacks
        self.manifests = manifests
        self.offers = offers
        self.installer = installer
        self.readiness = readiness
        self.dictationProbe = dictationProbe
        self.now = now
    }

    public var step: OnboardingStep {
        viewedStep ?? requiredStep
    }

    public var canGoBack: Bool {
        guard let index = OnboardingStep.allCases.firstIndex(of: step) else { return false }
        return index > OnboardingStep.allCases.startIndex
    }

    public func canVisit(_ step: OnboardingStep) -> Bool {
        guard let requested = OnboardingStep.allCases.firstIndex(of: step),
              let required = OnboardingStep.allCases.firstIndex(of: requiredStep)
        else { return false }
        return requested <= required
    }

    public func visit(_ step: OnboardingStep) {
        guard canVisit(step) else { return }
        viewedStep = step == requiredStep ? nil : step
    }

    public func goBack() {
        guard let index = OnboardingStep.allCases.firstIndex(of: step),
              index > OnboardingStep.allCases.startIndex
        else { return }
        visit(OnboardingStep.allCases[OnboardingStep.allCases.index(before: index)])
    }

    public var blockers: [OnboardingBlocker] {
        OnboardingPolicy.blockers(progress: progress, requirements: requirements)
    }

    /// The step that follows the one being viewed, or nil on the last one.
    public var nextStep: OnboardingStep? {
        guard let index = OnboardingStep.allCases.firstIndex(of: step) else { return nil }
        let next = OnboardingStep.allCases.index(after: index)
        guard next < OnboardingStep.allCases.endIndex else { return nil }
        return OnboardingStep.allCases[next]
    }

    /// Whether the one Continue button may act. The explanation and the first Dictation are steps
    /// Continue itself answers, so it is always live there; everywhere else Continue only moves
    /// forward, which the step rules already decide.
    public var canContinue: Bool {
        switch step {
        case .explanation, .firstDictation: true
        default: nextStep.map(canVisit) ?? false
        }
    }

    /// What the footer prints when Continue cannot act: the first missing prerequisite that the
    /// step being viewed, or a step before it, is responsible for. Naming a later step's work here
    /// would ask for something this surface is not showing yet, so the microphone step prints
    /// "Microphone access is not granted." and the shortcut test step prints "Input Monitoring is
    /// not granted." rather than both printing whichever blocker happens to be first in the list.
    ///
    /// A step whose own work is not a completion prerequisite — the offline readiness check —
    /// prints nothing; its body already says what is left to do.
    public var continueBlocker: String? {
        guard !canContinue, let current = OnboardingStep.allCases.firstIndex(of: step) else {
            return nil
        }
        return blockers.first { blocker in
            guard let asked = OnboardingStep.allCases.firstIndex(of: blocker.step) else {
                return false
            }
            return asked <= current
        }?.description
    }

    /// What the one Continue button does on each step: the explanation is acknowledged, the first
    /// Dictation is confirmed, and every other step simply moves on. Acknowledging also advances,
    /// so Continue still leaves a step that was revisited through Back.
    public func continueOnboarding() async {
        switch step {
        case .explanation:
            await acknowledgeExplanation()
            advance()
        case .firstDictation:
            await confirmFirstDictation()
        default:
            advance()
        }
    }

    private func advance() {
        guard let next = nextStep else { return }
        visit(next)
    }

    public var isComplete: Bool {
        OnboardingPolicy.isComplete(progress: progress, requirements: requirements)
    }

    /// Reads stored answers and the live system state. Onboarding resumes at whatever this leaves
    /// unfinished; it starts no download and prompts for no permission.
    public func load() async {
        progress = await settings.settings().onboarding
        await refresh()
    }

    public func refresh() async {
        let pack = (try? await modelPacks.activePack()) ?? nil
        let refreshed = OnboardingRequirements(
            permissions: .init(
                microphone: microphonePermission.state(),
                accessibility: accessibilityPermission.isGranted() ? .granted : .denied,
                keyboardMonitoring: keyboardPermission.isGranted() ? .granted : .denied
            ),
            hasActiveModelPack: pack != nil
        )
        if refreshed != requirements { viewedStep = nil }
        requirements = refreshed
        // A failure keeps its explanation even when an older pack is still installed; only a
        // surface that has said nothing yet adopts the installed pack.
        if case .idle = installState, let pack {
            installState = .installed(version: pack.version)
        }
    }

    public func acknowledgeExplanation() async {
        await update { $0.explanationAcknowledged = true }
    }

    public func requestMicrophonePermission() async {
        _ = await microphonePermission.request()
        await refresh()
    }

    public func requestAccessibilityPermission() async {
        _ = accessibilityPermission.request()
        await refresh()
    }

    public func requestKeyboardMonitoringPermission() async {
        _ = keyboardPermission.request()
        await refresh()
    }

    // MARK: Model Pack

    /// Fetches the signed manifest so the size and licenses can be shown. Downloading artifacts
    /// still needs a second, separate decision.
    public func describeModelPack() async {
        installState = .describing
        do {
            let signedManifest = try await manifests.signedManifest(
                for: .init(action: .onboardingInstall, version: nil))
            installState = .offered(try offers.describe(signedManifest: signedManifest))
        } catch {
            installState = .failed(ModelPackFailureMessage.text(for: error))
        }
    }

    /// Installs the described pack. This is the only place onboarding downloads anything.
    public func installModelPack() async {
        guard case .offered(let offer) = installState else { return }
        installState = .installing(offer)
        do {
            let installed = try await installer.perform(
                .onboardingInstall, signedManifest: offer.signedManifest)
            installState = .installed(version: installed.manifest.version)
        } catch {
            installState = .failed(ModelPackFailureMessage.text(for: error))
        }
        await refresh()
    }

    // MARK: Offline readiness

    public func runOfflineReadinessCheck() async {
        let report = await readiness.check()
        readinessReport = report
        if report.isReady {
            await update { $0.offlineReadinessConfirmed = true }
        }
    }

    // MARK: Shortcut test

    public func selectShortcut(_ binding: ShortcutBinding) async {
        await shortcut.select(binding)
        shortcutTestMessage = shortcut.deferredMessage
    }

    public func shortcutPressed() {
        shortcutPressSeen = true
        shortcut.shortcutPressed()
        shortcutTestMessage = "Holding \(shortcut.binding.displayName)…"
    }

    public func shortcutReleased() async {
        await shortcut.shortcutReleased()
        guard shortcutPressSeen else { return }
        shortcutPressSeen = false
        shortcutTestMessage = "\(shortcut.binding.displayName) works."
        guard !progress.shortcutTestPassed else { return }
        await update { $0.shortcutTestPassed = true }
    }

    // MARK: First Dictation

    /// Marks the moment the test began so a Dictation finished afterwards can be recognized without
    /// reading any transcript.
    public func beginFirstDictationTest() {
        firstDictationStartedAt = now()
        firstDictationMessage = "Hold \(shortcut.binding.displayName), say a sentence, then release."
    }

    public func confirmFirstDictation() async {
        guard let startedAt = firstDictationStartedAt else {
            firstDictationMessage = "Start the test first."
            return
        }
        guard await dictationProbe.hasDictation(since: startedAt) else {
            firstDictationMessage = "No Dictation has finished yet. Try holding the shortcut again."
            return
        }
        firstDictationMessage = "Your first Dictation is in History."
        await update { $0.firstDictationCompleted = true }
    }

    private func update(_ mutate: (inout OnboardingProgress) -> Void) async {
        var updated = progress
        mutate(&updated)
        guard updated != progress else { return }
        progress = updated
        viewedStep = nil
        try? await settings.setOnboardingProgress(updated)
    }

    private var requiredStep: OnboardingStep {
        OnboardingPolicy.currentStep(progress: progress, requirements: requirements)
    }

}
