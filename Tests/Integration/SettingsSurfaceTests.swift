import Foundation
import ModelRuntime
import Persistence
import SystemIntegration
import Testing

@testable import PoptartApplication

@Suite("Settings surface")
@MainActor
struct SettingsSurfaceTests {
    @Test("loading settings shows the microphones, permissions, pack, vocabulary, and login item")
    func loadPopulatesEverySection() async {
        let harness = SettingsHarness(
            devices: [.init(id: "built-in", name: "MacBook Pro Microphone")],
            currentMicrophone: "built-in",
            pack: .stub(version: "1.4.0"),
            storageBytes: 1_500_000_000,
            vocabulary: ["Poptart", "MLX"],
            launchesAtLogin: true
        )

        await harness.model.load()

        #expect(harness.model.microphones.map(\.id) == ["built-in"])
        #expect(harness.model.selectedMicrophoneIdentifier == "built-in")
        #expect(harness.model.permissions.microphone == .granted)
        #expect(harness.model.modelPack?.version == "1.4.0")
        #expect(harness.model.modelPack?.storageBytes == 1_500_000_000)
        #expect(harness.model.modelPack?.licenses.map(\.role).sorted() == ["cleanup", "recognition"])
        #expect(harness.model.vocabularyDraft == "Poptart\nMLX")
        #expect(harness.model.launchesAtLogin)
    }

    @Test("choosing a microphone points capture at it and remembers the choice")
    func choosingAMicrophoneRoutesAndPersists() async {
        let harness = SettingsHarness(
            devices: [
                .init(id: "built-in", name: "MacBook Pro Microphone"),
                .init(id: "usb", name: "Podcast Microphone"),
            ],
            currentMicrophone: "built-in"
        )
        await harness.model.load()

        await harness.model.selectMicrophone("usb")

        #expect(harness.router.selections.value == ["usb"])
        #expect(harness.model.selectedMicrophoneIdentifier == "usb")
        #expect(await harness.settings.stored.microphoneDeviceIdentifier == "usb")
        #expect(harness.model.microphoneMessage == nil)
    }

    @Test("a microphone macOS refuses to switch to is explained and not remembered")
    func refusedMicrophoneIsExplained() async {
        let harness = SettingsHarness(
            devices: [.init(id: "usb", name: "Podcast Microphone")],
            currentMicrophone: "built-in",
            unavailableMicrophones: ["usb"]
        )

        await harness.model.selectMicrophone("usb")

        #expect(harness.model.microphoneMessage == "macOS did not switch to that microphone.")
        #expect(await harness.settings.stored.microphoneDeviceIdentifier == nil)
        #expect(harness.model.selectedMicrophoneIdentifier == "built-in")
    }

    @Test("the remembered microphone is reapplied only when the Mac starts on another one")
    func preferredMicrophoneIsRestored() async {
        let harness = SettingsHarness(
            currentMicrophone: "built-in",
            storedMicrophone: "usb"
        )

        await harness.model.restorePreferredMicrophone()
        #expect(harness.router.selections.value == ["usb"])

        await harness.model.restorePreferredMicrophone()
        #expect(harness.router.selections.value == ["usb"], "nothing to do when it already matches")
    }

    @Test("launch at login follows the login item, and a refusal is explained")
    func launchAtLoginFollowsTheLoginItem() async {
        let harness = SettingsHarness()

        await harness.model.setLaunchesAtLogin(true)
        #expect(harness.model.launchesAtLogin)
        #expect(harness.model.launchAtLoginMessage == nil)

        let refusing = SettingsHarness(launchAtLogin: StubLaunchAtLogin(refuses: true))
        await refusing.model.setLaunchesAtLogin(true)
        #expect(refusing.model.launchesAtLogin == false)
        #expect(refusing.model.launchAtLoginMessage == "macOS refused to change the login item.")
    }

    @Test("checking for a Model Pack update offers a newer pack and downloads nothing")
    func checkOffersNewerPack() async {
        let harness = SettingsHarness(pack: .stub(version: "1.0.0"))
        await harness.model.refreshModelPack()

        await harness.model.checkForModelPackUpdate()

        #expect(harness.model.availableModelPack?.version == "1.2.0")
        #expect(await harness.manifests.requests.map(\.action) == [.update])
        #expect(await harness.installer.performed.isEmpty)
        #expect(harness.model.modelPackActivity.statusText?.contains("1.2.0") == true)
    }

    @Test("checking while already current offers nothing to install")
    func checkWithCurrentPackOffersNothing() async {
        let harness = SettingsHarness(pack: .stub(version: "1.2.0"))
        await harness.model.refreshModelPack()

        await harness.model.checkForModelPackUpdate()

        #expect(harness.model.availableModelPack == nil)
        #expect(
            harness.model.modelPackActivity == .reported("Poptart already has Model Pack 1.2.0."))
    }

    @Test("updating installs the checked pack and never runs unchecked")
    func updateRequiresACheckFirst() async {
        let harness = SettingsHarness(pack: .stub(version: "1.0.0"))
        await harness.model.refreshModelPack()

        await harness.model.updateModelPack()
        #expect(await harness.installer.performed.isEmpty)
        #expect(harness.model.modelPackActivity == .reported("Check for a Model Pack update first."))

        await harness.model.checkForModelPackUpdate()
        await harness.installer.result(.stub(version: "1.2.0"))
        await harness.model.updateModelPack()

        #expect(await harness.installer.performed.map(\.action) == [.update])
        #expect(harness.model.modelPackActivity == .reported("Model Pack 1.2.0 is active."))
        #expect(harness.model.availableModelPack == nil)
    }

    @Test("Repair Model Pack reinstalls the version that should be installed")
    func repairReinstallsTheInstalledVersion() async {
        let harness = SettingsHarness(pack: .stub(version: "1.0.0"))
        await harness.model.refreshModelPack()
        await harness.installer.result(.stub(version: "1.0.0"))

        await harness.model.repairModelPack()

        let requests = await harness.manifests.requests
        #expect(requests.map(\.action) == [.repair])
        #expect(requests.map(\.version) == ["1.0.0"])
        #expect(await harness.installer.performed.map(\.action) == [.repair])
        #expect(harness.model.modelPackActivity == .reported("Model Pack 1.0.0 verifies again."))
    }

    @Test("a development Model Pack says plainly that there is nothing to repair")
    func developmentPackHasNothingToRepair() async {
        let harness = SettingsHarness(
            pack: .stub(version: "0.9.0 (development)", origin: .development))
        await harness.model.refreshModelPack()
        #expect(harness.model.modelPack?.repairableVersion == nil)

        await harness.model.repairModelPack()

        #expect(
            harness.model.modelPackActivity
                == .reported(
                    "This development Model Pack was not installed by Poptart, so there is nothing to repair."
                ))
        #expect(await harness.manifests.requests.isEmpty)
        #expect(await harness.installer.performed.isEmpty)
    }

    @Test("repair still recovers a Mac with no readable pack at all")
    func repairRecoversAnEmptyRegistry() async {
        let harness = SettingsHarness(packFailure: ModelPackError.invalidActiveState)
        await harness.model.refreshModelPack()

        await harness.model.repairModelPack()

        let requests = await harness.manifests.requests
        #expect(requests.map(\.action) == [.repair])
        #expect(requests.map(\.version) == [String?.none])
        #expect(await harness.installer.performed.map(\.action) == [.repair])
    }

    @Test("an unreadable pack registry points at the repair action that exists")
    func unreadableRegistryPointsAtRepair() async {
        let harness = SettingsHarness(packFailure: ModelPackError.invalidActiveState)

        await harness.model.refreshModelPack()

        #expect(harness.model.modelPack == nil)
        #expect(
            harness.model.modelPackActivity
                == .reported("The installed Model Pack no longer verifies. Use Repair Model Pack."))
    }

    @Test("a pack with no measured Cleanup budget says Dictations keep the Raw Transcript")
    func packWithoutMeasuredCeilingIsExplained() async {
        let harness = SettingsHarness(pack: .stub(version: "0.9.0", cleanupTokenCeiling: nil))

        await harness.model.refreshModelPack()

        #expect(harness.model.modelPack?.cleanupTokenCeiling == nil)
        #expect(
            harness.model.modelPack?.cleanupDescription
                == "This pack ships no measured Cleanup budget, so Dictations keep the Raw Transcript."
        )
    }

    @Test("saving Personal Vocabulary keeps one term per line, in order, without repeats")
    func vocabularySaveNormalizes() async {
        let harness = SettingsHarness(vocabulary: [])
        harness.model.vocabularyDraft = "  Poptart \n\nMLX\nPoptart\n   \nParakeet"

        await harness.model.saveVocabulary()

        #expect(await harness.vocabulary.stored == ["Poptart", "MLX", "Parakeet"])
        #expect(harness.model.vocabularyDraft == "Poptart\nMLX\nParakeet")
        #expect(harness.model.vocabularyMessage == "Saved 3 terms on this Mac.")
    }

    @Test("vocabulary that cannot be decrypted is reported rather than silently emptied")
    func unreadableVocabularyIsReported() async {
        let harness = SettingsHarness(
            vocabularyStore: StubVocabulary(readFailure: StubError("unreadable")))

        await harness.model.loadVocabulary()

        #expect(harness.model.vocabularyMessage == "Personal Vocabulary cannot be read on this Mac.")
    }

    @Test("the update check opens the releases page and asks the network for nothing")
    func updateCheckOpensReleasesPage() async {
        let harness = SettingsHarness()

        harness.model.checkForApplicationUpdate()

        #expect(harness.links.opened.value == [PoptartRelease.releasesURL])
        #expect(await harness.manifests.requests.isEmpty)
        #expect(
            harness.model.applicationUpdateMessage
                == "Opened the Poptart releases page. Poptart never checks for updates on its own.")
    }

    @Test("only the missing permissions are requested")
    func onlyMissingPermissionsAreRequested() async {
        let harness = SettingsHarness(
            microphone: .granted, accessibilityGranted: false, keyboardGranted: true)
        await harness.model.refreshPermissions()

        await harness.model.requestMissingPermissions()

        #expect(harness.microphone.requests.value == 0)
        #expect(harness.accessibility.requests.value == 1)
        #expect(harness.keyboard.requests.value == 0)
        #expect(harness.model.permissions.allGranted)
    }

    @Test("Clear History in settings empties the same Dictation Records history shows")
    func clearHistoryEmptiesTheRecords() async {
        let harness = SettingsHarness(records: [stubRecord(), stubRecord()])
        await harness.model.history.reload()
        #expect(harness.model.history.records.count == 2)

        await harness.model.clearHistory()

        #expect(harness.model.history.records.isEmpty)
        #expect(await harness.records.cleared == 1)
        #expect(harness.model.historyRetentionDescription.contains("30 days"))
    }

    @Test("the settings shortcut picker and the onboarding test share one binding")
    func shortcutPickerSharesTheBinding() async {
        let harness = SettingsHarness()

        await harness.model.shortcut.select(.rightControl)

        #expect(harness.model.shortcut.binding == .rightControl)
        #expect(harness.applied.value == [.rightControl])
        #expect(await harness.settings.stored.shortcutBinding == .rightControl)
    }
}

@MainActor
private struct SettingsHarness {
    let settings: StubSettingsStore
    let router: StubMicrophoneRouter
    let microphone: StubMicrophonePermission
    let accessibility: StubAccessibilityPermission
    let keyboard: StubKeyboardPermission
    let manifests: StubManifestSource
    let installer: StubInstaller
    let vocabulary: StubVocabulary
    let records: StubRecordStore
    let links: StubLinkOpener
    let applied: Box<[ShortcutBinding]>
    let model: SettingsModel

    init(
        devices: [MicrophoneDevice] = [.init(id: "built-in", name: "MacBook Pro Microphone")],
        currentMicrophone: String? = nil,
        unavailableMicrophones: Set<String> = [],
        storedMicrophone: String? = nil,
        microphone: PermissionState = .granted,
        accessibilityGranted: Bool = true,
        keyboardGranted: Bool = true,
        pack: ActiveApplicationModelPack? = nil,
        packFailure: (any Error)? = nil,
        storageBytes: Int64 = 1_000,
        vocabulary: [String] = [],
        vocabularyStore: StubVocabulary? = nil,
        records: [Persistence.DictationRecord] = [],
        launchesAtLogin: Bool = false,
        launchAtLogin: StubLaunchAtLogin? = nil
    ) {
        let settings = StubSettingsStore(
            .init(
                shortcutBinding: .rightOption,
                microphoneDeviceIdentifier: storedMicrophone,
                onboarding: .initial
            ))
        let applied = Box<[ShortcutBinding]>([])
        let shortcut = ShortcutBindingModel(binding: .rightOption, settings: settings) { binding in
            applied.mutate { $0.append(binding) }
        }
        let recordStore = StubRecordStore(stored: records)
        let history = HistoryListModel(store: recordStore, clipboard: StubClipboard())
        self.settings = settings
        self.applied = applied
        self.router = StubMicrophoneRouter(
            current: currentMicrophone, unavailable: unavailableMicrophones)
        self.microphone = StubMicrophonePermission(microphone)
        self.accessibility = StubAccessibilityPermission(granted: accessibilityGranted)
        self.keyboard = StubKeyboardPermission(granted: keyboardGranted)
        self.manifests = StubManifestSource()
        self.installer = StubInstaller()
        self.vocabulary = vocabularyStore ?? StubVocabulary(stored: vocabulary)
        self.records = recordStore
        self.links = StubLinkOpener()
        self.model = SettingsModel(
            shortcut: shortcut,
            history: history,
            settings: settings,
            deviceEnumerator: StubDeviceEnumerator(available: devices),
            microphoneRouter: router,
            microphonePermission: self.microphone,
            accessibilityPermission: self.accessibility,
            keyboardPermission: self.keyboard,
            launchAtLogin: launchAtLogin ?? StubLaunchAtLogin(enabled: launchesAtLogin),
            modelPacks: StubModelPackProvider(pack: pack, failure: packFailure),
            manifests: self.manifests,
            offers: StubOfferDescriber(),
            installer: self.installer,
            storage: StubStorageMeasure(bytes: storageBytes),
            vocabulary: self.vocabulary,
            links: self.links,
            applicationVersion: "0.1.0"
        )
    }
}
