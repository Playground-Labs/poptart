import Foundation
import ModelRuntime
import SystemIntegration
import Testing

@testable import PoptartApplication

@Suite("Onboarding policy")
struct OnboardingPolicyTests {
    private let everythingGranted = PermissionSnapshot(
        microphone: .granted, accessibility: .granted, keyboardMonitoring: .granted)

    private var finished: OnboardingProgress {
        .init(
            explanationAcknowledged: true,
            offlineReadinessConfirmed: true,
            shortcutTestPassed: true,
            firstDictationCompleted: true
        )
    }

    @Test("onboarding resumes at the first unfinished step")
    func resumesAtFirstUnfinishedStep() {
        var progress = OnboardingProgress.initial
        var requirements = OnboardingRequirements.unknown
        #expect(
            OnboardingPolicy.currentStep(progress: progress, requirements: requirements)
                == .explanation)

        progress.explanationAcknowledged = true
        #expect(
            OnboardingPolicy.currentStep(progress: progress, requirements: requirements)
                == .microphonePermission)

        requirements.permissions.microphone = .granted
        #expect(
            OnboardingPolicy.currentStep(progress: progress, requirements: requirements)
                == .accessibilityPermission)

        requirements.permissions.accessibility = .granted
        #expect(
            OnboardingPolicy.currentStep(progress: progress, requirements: requirements)
                == .modelPack)

        requirements.hasActiveModelPack = true
        #expect(
            OnboardingPolicy.currentStep(progress: progress, requirements: requirements)
                == .offlineReadiness)

        progress.offlineReadinessConfirmed = true
        #expect(
            OnboardingPolicy.currentStep(progress: progress, requirements: requirements)
                == .shortcutTest)

        requirements.permissions.keyboardMonitoring = .granted
        progress.shortcutTestPassed = true
        #expect(
            OnboardingPolicy.currentStep(progress: progress, requirements: requirements)
                == .firstDictation)
    }

    @Test(
        "each missing prerequisite blocks completion on its own",
        arguments: [
            OnboardingBlocker.microphonePermission,
            .accessibilityPermission,
            .keyboardMonitoringPermission,
            .activeModelPack,
            .shortcutTest,
        ]
    )
    func eachMissingPrerequisiteBlocksCompletion(missing: OnboardingBlocker) {
        var progress = finished
        var requirements = OnboardingRequirements(
            permissions: everythingGranted, hasActiveModelPack: true)
        switch missing {
        case .microphonePermission: requirements.permissions.microphone = .denied
        case .accessibilityPermission: requirements.permissions.accessibility = .denied
        case .keyboardMonitoringPermission: requirements.permissions.keyboardMonitoring = .denied
        case .activeModelPack: requirements.hasActiveModelPack = false
        case .shortcutTest: progress.shortcutTestPassed = false
        }

        #expect(
            OnboardingPolicy.isComplete(progress: progress, requirements: requirements) == false)
        #expect(
            OnboardingPolicy.blockers(progress: progress, requirements: requirements) == [missing])
    }

    @Test("completion needs the explanation, the readiness check, and a first Dictation as well")
    func completionNeedsEveryStep() {
        let requirements = OnboardingRequirements(
            permissions: everythingGranted, hasActiveModelPack: true)
        #expect(OnboardingPolicy.isComplete(progress: finished, requirements: requirements))

        var withoutExplanation = finished
        withoutExplanation.explanationAcknowledged = false
        var withoutReadiness = finished
        withoutReadiness.offlineReadinessConfirmed = false
        var withoutFirstDictation = finished
        withoutFirstDictation.firstDictationCompleted = false

        for incomplete in [withoutExplanation, withoutReadiness, withoutFirstDictation] {
            #expect(
                OnboardingPolicy.isComplete(progress: incomplete, requirements: requirements)
                    == false)
        }
    }
}

@Suite("Onboarding surface")
@MainActor
struct OnboardingSurfaceTests {
    @Test("completed onboarding steps remain available through Back")
    func completedStepsRemainAvailableThroughBack() async {
        let progress = OnboardingProgress(
            explanationAcknowledged: true,
            offlineReadinessConfirmed: true,
            shortcutTestPassed: true,
            firstDictationCompleted: false
        )
        let harness = OnboardingHarness(
            progress: progress,
            microphone: .granted,
            accessibilityGranted: true,
            keyboardGranted: true,
            pack: .stub()
        )
        await harness.model.load()
        #expect(harness.model.step == .firstDictation)

        harness.model.goBack()

        #expect(harness.model.step == .shortcutTest)
        await harness.model.selectShortcut(.leftOption)
        #expect(harness.model.shortcut.binding == .leftOption)
        #expect(harness.model.progress == progress)

        harness.model.visit(.firstDictation)
        #expect(harness.model.step == .firstDictation)
    }

    @Test("onboarding resumes where the person left off after a relaunch")
    func resumesAfterRelaunch() async {
        let harness = OnboardingHarness(
            progress: .init(
                explanationAcknowledged: true,
                offlineReadinessConfirmed: true,
                shortcutTestPassed: false,
                firstDictationCompleted: false
            ),
            microphone: .granted,
            accessibilityGranted: true,
            keyboardGranted: true,
            pack: .stub()
        )

        await harness.model.load()

        #expect(harness.model.step == .shortcutTest)
        #expect(harness.model.isComplete == false)
        #expect(harness.model.blockers == [.shortcutTest])
    }

    @Test("loading onboarding downloads nothing")
    func loadingDownloadsNothing() async {
        let harness = OnboardingHarness()

        await harness.model.load()
        await harness.model.refresh()

        #expect(await harness.manifests.requests.isEmpty)
        #expect(await harness.installer.performed.isEmpty)
    }

    @Test("the Model Pack is described before anything downloads")
    func modelPackIsDescribedBeforeDownloading() async {
        let harness = OnboardingHarness()

        await harness.model.describeModelPack()

        #expect(await harness.manifests.requests.map(\.action) == [.onboardingInstall])
        #expect(await harness.installer.performed.isEmpty)
        #expect(harness.model.installState.offer?.version == "1.2.0")
        #expect(harness.model.installState.statusText?.contains("1.2.0") == true)
    }

    @Test("installing the Model Pack is a second, explicit decision")
    func installingIsExplicit() async {
        let harness = OnboardingHarness()
        await harness.installer.result(.stub(version: "1.2.0"))

        await harness.model.installModelPack()
        #expect(await harness.installer.performed.isEmpty, "nothing installs before it is described")

        await harness.model.describeModelPack()
        await harness.model.installModelPack()

        let performed = await harness.installer.performed
        #expect(performed.map(\.action) == [.onboardingInstall])
        #expect(harness.model.installState == .installed(version: "1.2.0"))
    }

    @Test("a refused download explains itself and installs nothing")
    func failedInstallExplainsItself() async {
        let harness = OnboardingHarness()
        await harness.installer.fail(with: ModelPackError.artifactHashMismatch(.cleanup))

        await harness.model.describeModelPack()
        await harness.model.installModelPack()

        #expect(
            harness.model.installState
                == .failed("A downloaded file did not match its published hash. Poptart installed nothing.")
        )
    }

    @Test("a failed download keeps its explanation while the older pack stays active")
    func failedInstallKeepsItsExplanation() async {
        let harness = OnboardingHarness(pack: .stub(version: "1.0.0"))
        await harness.installer.fail(with: ModelPackError.smokeTestFailed)

        await harness.model.describeModelPack()
        await harness.model.installModelPack()

        #expect(
            harness.model.installState
                == .failed("The downloaded Model Pack did not load. The previous pack is still active.")
        )
    }

    @Test("a build with no signing key refuses to describe a Model Pack")
    func missingSigningKeyRefusesDescription() async {
        let harness = OnboardingHarness(manifests: StubManifestSource(
            failure: ModelPackTrustError.signingKeyMissing))

        await harness.model.describeModelPack()

        #expect(
            harness.model.installState
                == .failed(
                    "This build carries no Model Pack signing key, so it cannot verify a download.")
        )
    }

    @Test("holding and releasing the shortcut passes the test and is remembered")
    func shortcutTestPassesAndPersists() async {
        let harness = OnboardingHarness(
            progress: .init(
                explanationAcknowledged: true,
                offlineReadinessConfirmed: true,
                shortcutTestPassed: false,
                firstDictationCompleted: false
            ),
            microphone: .granted,
            accessibilityGranted: true,
            keyboardGranted: true,
            pack: .stub()
        )
        await harness.model.load()

        harness.model.shortcutPressed()
        await harness.model.shortcutReleased()

        #expect(harness.model.progress.shortcutTestPassed)
        #expect(await harness.settings.stored.onboarding.shortcutTestPassed)
        #expect(harness.model.step == .firstDictation)
    }

    @Test("a release Poptart never saw a press for does not pass the test")
    func releaseWithoutPressDoesNotPass() async {
        let harness = OnboardingHarness()

        await harness.model.shortcutReleased()

        #expect(harness.model.progress.shortcutTestPassed == false)
    }

    @Test("rebinding during the shortcut test waits for the held key to be released")
    func rebindDuringHeldKeyIsDeferred() async {
        let harness = OnboardingHarness()

        harness.model.shortcutPressed()
        await harness.model.selectShortcut(.leftCommand)

        #expect(harness.model.shortcut.binding == .rightOption)
        #expect(harness.applied.value.isEmpty)

        await harness.model.shortcutReleased()

        #expect(harness.model.shortcut.binding == .leftCommand)
        #expect(harness.applied.value == [.leftCommand])
    }

    @Test("the offline readiness check is only confirmed when the Mac is actually ready")
    func offlineReadinessMustSucceed() async {
        let denied = PermissionSnapshot(
            microphone: .granted, accessibility: .granted, keyboardMonitoring: .denied)
        let readiness = StubReadinessCheck(
            report: .init(
                modelPackVerified: false,
                permissions: denied,
                failureDescription: "No Model Pack is installed yet."
            ))
        let harness = OnboardingHarness(readiness: readiness)

        await harness.model.runOfflineReadinessCheck()
        #expect(harness.model.progress.offlineReadinessConfirmed == false)
        #expect(harness.model.readinessReport?.isReady == false)

        await readiness.set(
            .init(
                modelPackVerified: true,
                permissions: .init(
                    microphone: .granted, accessibility: .granted, keyboardMonitoring: .granted),
                failureDescription: nil
            ))
        await harness.model.runOfflineReadinessCheck()

        #expect(harness.model.progress.offlineReadinessConfirmed)
        #expect(await harness.settings.stored.onboarding.offlineReadinessConfirmed)
    }

    @Test(
        "offline readiness passes before Input Monitoring exists, so the shortcut step can grant it"
    )
    func offlineReadinessDoesNotWaitForInputMonitoring() async throws {
        // The real check over a real installed pack, because a stub here would hide the deadlock
        // this test exists to prevent.
        let root = try TemporaryDirectory()
        try root.installPack(version: "1.2.0", cleanupTokenCeiling: 768)
        let microphone = StubMicrophonePermission(.granted)
        let accessibility = StubAccessibilityPermission(granted: true)
        let keyboard = StubKeyboardPermission(granted: false)
        let harness = OnboardingHarness(
            progress: .init(
                explanationAcknowledged: true,
                offlineReadinessConfirmed: false,
                shortcutTestPassed: false,
                firstDictationCompleted: false
            ),
            microphonePermission: microphone,
            accessibilityPermission: accessibility,
            keyboardPermission: keyboard,
            pack: .stub(version: "1.2.0"),
            readiness: InstalledPackOfflineReadiness(
                modelRuntimeDirectory: root.url,
                manifestPublicKey: root.publicKey,
                permissions: {
                    .init(
                        microphone: microphone.state(),
                        accessibility: accessibility.isGranted() ? .granted : .denied,
                        keyboardMonitoring: keyboard.isGranted() ? .granted : .denied
                    )
                }
            )
        )
        await harness.model.load()
        #expect(harness.model.step == .offlineReadiness)

        await harness.model.runOfflineReadinessCheck()

        #expect(harness.model.readinessReport?.isReady == true)
        #expect(harness.model.progress.offlineReadinessConfirmed)
        #expect(
            harness.model.step == .shortcutTest,
            "the step that grants Input Monitoring must be reachable"
        )
        #expect(harness.model.isComplete == false)
        #expect(harness.model.blockers.contains(.keyboardMonitoringPermission))

        await harness.model.requestKeyboardMonitoringPermission()
        harness.model.shortcutPressed()
        await harness.model.shortcutReleased()
        harness.model.beginFirstDictationTest()
        await harness.probe.complete(at: Date(timeIntervalSince1970: 5_001))
        await harness.model.confirmFirstDictation()

        #expect(harness.model.blockers.isEmpty)
        #expect(harness.model.isComplete)
    }

    @Test("the first Dictation test only passes once a Dictation has finished")
    func firstDictationTestNeedsARealDictation() async {
        let started = Date(timeIntervalSince1970: 5_000)
        let harness = OnboardingHarness(now: { started })

        await harness.model.confirmFirstDictation()
        #expect(harness.model.firstDictationMessage == "Start the test first.")

        harness.model.beginFirstDictationTest()
        await harness.model.confirmFirstDictation()
        #expect(harness.model.progress.firstDictationCompleted == false)

        await harness.probe.complete(at: started.addingTimeInterval(3))
        await harness.model.confirmFirstDictation()

        #expect(harness.model.progress.firstDictationCompleted)
        #expect(await harness.probe.probes.allSatisfy { $0 == started })
    }

    @Test("granting a permission moves onboarding forward without a relaunch")
    func grantingPermissionAdvancesTheStep() async {
        let harness = OnboardingHarness(
            progress: .init(
                explanationAcknowledged: true,
                offlineReadinessConfirmed: false,
                shortcutTestPassed: false,
                firstDictationCompleted: false
            ))
        await harness.model.load()
        #expect(harness.model.step == .microphonePermission)

        await harness.model.requestMicrophonePermission()

        #expect(harness.model.step == .accessibilityPermission)
        #expect(harness.microphone.requests.value == 1)
    }

    @Test("Continue on the explanation acknowledges it and moves to the microphone step")
    func continueAcknowledgesTheExplanation() async {
        let harness = OnboardingHarness()
        await harness.model.load()
        #expect(harness.model.step == .explanation)
        #expect(harness.model.canContinue)
        #expect(harness.model.nextStep == .microphonePermission)

        await harness.model.continueOnboarding()

        #expect(harness.model.progress.explanationAcknowledged)
        #expect(await harness.settings.stored.onboarding.explanationAcknowledged)
        #expect(harness.model.step == .microphonePermission)
    }

    @Test("Continue names what the current step is still waiting for")
    func continueNamesTheBlockerForTheCurrentStep() async {
        let harness = OnboardingHarness(
            progress: .init(
                explanationAcknowledged: true,
                offlineReadinessConfirmed: false,
                shortcutTestPassed: false,
                firstDictationCompleted: false
            ))
        await harness.model.load()

        #expect(harness.model.step == .microphonePermission)
        #expect(harness.model.canContinue == false)
        #expect(harness.model.continueBlocker == "Microphone access is not granted.")
    }

    @Test("Continue waits on the shortcut step for Input Monitoring and a passing test")
    func continueIsBlockedUntilTheShortcutTestPasses() async {
        let harness = OnboardingHarness(
            progress: .init(
                explanationAcknowledged: true,
                offlineReadinessConfirmed: true,
                shortcutTestPassed: false,
                firstDictationCompleted: false
            ),
            microphone: .granted,
            accessibilityGranted: true,
            keyboardGranted: false,
            pack: .stub()
        )
        await harness.model.load()
        #expect(harness.model.step == .shortcutTest)
        #expect(harness.model.canContinue == false)
        #expect(harness.model.continueBlocker == "Input Monitoring is not granted.")

        await harness.model.requestKeyboardMonitoringPermission()
        #expect(harness.model.canContinue == false)
        #expect(harness.model.continueBlocker == "The shortcut test has not succeeded.")

        harness.model.shortcutPressed()
        await harness.model.shortcutReleased()

        #expect(harness.model.canContinue)
        #expect(harness.model.continueBlocker == nil)
    }

    @Test("the footer names the Model Pack, not a permission a later step asks for")
    func continueIgnoresBlockersFromLaterSteps() async {
        let harness = OnboardingHarness(
            progress: .init(
                explanationAcknowledged: true,
                offlineReadinessConfirmed: false,
                shortcutTestPassed: false,
                firstDictationCompleted: false
            ),
            microphone: .granted,
            accessibilityGranted: true,
            keyboardGranted: false
        )
        await harness.model.load()

        #expect(harness.model.step == .modelPack)
        #expect(harness.model.blockers.first == .keyboardMonitoringPermission)
        #expect(harness.model.continueBlocker == "No verified Model Pack is active.")
    }

    @Test("Continue on the last step confirms the first Dictation")
    func continueConfirmsTheFirstDictation() async {
        let started = Date(timeIntervalSince1970: 5_000)
        let harness = OnboardingHarness(
            progress: .init(
                explanationAcknowledged: true,
                offlineReadinessConfirmed: true,
                shortcutTestPassed: true,
                firstDictationCompleted: false
            ),
            microphone: .granted,
            accessibilityGranted: true,
            keyboardGranted: true,
            pack: .stub(),
            now: { started }
        )
        await harness.model.load()
        #expect(harness.model.step == .firstDictation)
        #expect(harness.model.nextStep == nil, "the last step has nothing after it")
        #expect(harness.model.canContinue)

        harness.model.beginFirstDictationTest()
        await harness.probe.complete(at: started.addingTimeInterval(2))
        await harness.model.continueOnboarding()

        #expect(harness.model.progress.firstDictationCompleted)
        #expect(harness.model.isComplete)
    }

    @Test("an installed pack is reported without asking the release channel")
    func installedPackIsReportedOffline() async {
        let harness = OnboardingHarness(pack: .stub(version: "3.1.0"))

        await harness.model.refresh()

        #expect(harness.model.installState == .installed(version: "3.1.0"))
        #expect(await harness.manifests.requests.isEmpty)
    }
}

@MainActor
private struct OnboardingHarness {
    let settings: StubSettingsStore
    let microphone: StubMicrophonePermission
    let accessibility: StubAccessibilityPermission
    let keyboard: StubKeyboardPermission
    let packs: StubModelPackProvider
    let manifests: StubManifestSource
    let installer: StubInstaller
    let readiness: any OfflineReadinessChecking
    let probe: StubDictationProbe
    let applied: Box<[ShortcutBinding]>
    let model: OnboardingModel

    init(
        progress: OnboardingProgress = .initial,
        microphone: PermissionState = .undetermined,
        accessibilityGranted: Bool = false,
        keyboardGranted: Bool = false,
        microphonePermission: StubMicrophonePermission? = nil,
        accessibilityPermission: StubAccessibilityPermission? = nil,
        keyboardPermission: StubKeyboardPermission? = nil,
        pack: ActiveApplicationModelPack? = nil,
        manifests: StubManifestSource = StubManifestSource(),
        readiness: (any OfflineReadinessChecking)? = nil,
        readinessDefault: StubReadinessCheck = StubReadinessCheck(
            report: .init(
                modelPackVerified: true,
                permissions: .init(
                    microphone: .granted, accessibility: .granted, keyboardMonitoring: .granted),
                failureDescription: nil
            )),
        now: @escaping @Sendable () -> Date = { Date(timeIntervalSince1970: 5_000) }
    ) {
        let settings = StubSettingsStore(
            .init(
                shortcutBinding: .rightOption,
                microphoneDeviceIdentifier: nil,
                onboarding: progress
            ))
        let applied = Box<[ShortcutBinding]>([])
        let shortcut = ShortcutBindingModel(binding: .rightOption, settings: settings) { binding in
            applied.mutate { $0.append(binding) }
        }
        self.settings = settings
        self.applied = applied
        self.microphone = microphonePermission ?? StubMicrophonePermission(microphone)
        self.accessibility =
            accessibilityPermission ?? StubAccessibilityPermission(granted: accessibilityGranted)
        self.keyboard = keyboardPermission ?? StubKeyboardPermission(granted: keyboardGranted)
        self.packs = StubModelPackProvider(pack: pack)
        self.manifests = manifests
        self.installer = StubInstaller()
        self.readiness = readiness ?? readinessDefault
        self.probe = StubDictationProbe()
        self.model = OnboardingModel(
            shortcut: shortcut,
            settings: settings,
            microphonePermission: self.microphone,
            accessibilityPermission: self.accessibility,
            keyboardPermission: self.keyboard,
            modelPacks: self.packs,
            manifests: self.manifests,
            offers: StubOfferDescriber(),
            installer: self.installer,
            readiness: self.readiness,
            dictationProbe: self.probe,
            now: now
        )
    }
}
