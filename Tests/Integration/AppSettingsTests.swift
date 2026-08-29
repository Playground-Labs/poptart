import Foundation
import SystemIntegration
import Testing

@testable import PoptartApplication

@Suite("Application settings storage")
struct AppSettingsStoreTests {
    @Test("the chosen shortcut survives a relaunch")
    func shortcutRoundTrips() async throws {
        let directory = try TemporaryDirectory()

        let store = try AppSettingsStore(directory: directory.url)
        try await store.setShortcutBinding(.leftCommand)

        let reopened = try AppSettingsStore(directory: directory.url)
        #expect(await reopened.settings().shortcutBinding == .leftCommand)
    }

    @Test("a shortcut identifier this build does not support falls back to Right Option")
    func unsupportedShortcutIdentifierFallsBack() async throws {
        let directory = try TemporaryDirectory()
        try Data(#"{"shortcutBinding":"rightFunction"}"#.utf8).write(
            to: directory.url.appendingPathComponent("Settings.json"))

        let store = try AppSettingsStore(directory: directory.url)

        #expect(await store.settings().shortcutBinding == .rightOption)
    }

    @Test("an unreadable settings file yields the documented defaults")
    func unreadableFileYieldsDefaults() async throws {
        let directory = try TemporaryDirectory()
        try Data("not json".utf8).write(
            to: directory.url.appendingPathComponent("Settings.json"))

        let store = try AppSettingsStore(directory: directory.url)
        let settings = await store.settings()

        #expect(settings == .defaults)
        #expect(settings.shortcutBinding == .rightOption)
    }

    @Test("onboarding answers and the microphone choice survive a relaunch")
    func onboardingAndMicrophoneRoundTrip() async throws {
        let directory = try TemporaryDirectory()
        let progress = OnboardingProgress(
            explanationAcknowledged: true,
            offlineReadinessConfirmed: true,
            shortcutTestPassed: true,
            firstDictationCompleted: false
        )

        let store = try AppSettingsStore(directory: directory.url)
        try await store.setOnboardingProgress(progress)
        try await store.setMicrophoneDeviceIdentifier("device-7")

        let reopened = try AppSettingsStore(directory: directory.url)
        let settings = await reopened.settings()
        #expect(settings.onboarding == progress)
        #expect(settings.microphoneDeviceIdentifier == "device-7")
    }

    @Test("an answer an older build never wrote counts as not done")
    func missingOnboardingAnswersCountAsNotDone() async throws {
        let directory = try TemporaryDirectory()
        try Data(#"{"onboarding":{"shortcutTestPassed":true}}"#.utf8).write(
            to: directory.url.appendingPathComponent("Settings.json"))

        let store = try AppSettingsStore(directory: directory.url)
        let progress = await store.settings().onboarding

        #expect(progress.shortcutTestPassed)
        #expect(progress.explanationAcknowledged == false)
        #expect(progress.firstDictationCompleted == false)
    }
}

@Suite("Dictation shortcut binding")
struct ShortcutBindingModelTests {
    @MainActor
    private func makeModel(
        binding: ShortcutBinding = .rightOption,
        store: StubSettingsStore = StubSettingsStore(),
        applied: Box<[ShortcutBinding]> = Box([])
    ) -> ShortcutBindingModel {
        ShortcutBindingModel(binding: binding, settings: store) { newBinding in
            applied.mutate { $0.append(newBinding) }
        }
    }

    @Test("choosing a key rebinds the monitor and persists the choice")
    @MainActor
    func selectionRebindsAndPersists() async {
        let store = StubSettingsStore()
        let applied = Box<[ShortcutBinding]>([])
        let model = makeModel(store: store, applied: applied)

        await model.select(.leftControl)

        #expect(model.binding == .leftControl)
        #expect(applied.value == [.leftControl])
        #expect(await store.stored.shortcutBinding == .leftControl)
    }

    @Test("a key chosen while the shortcut is held waits for the release")
    @MainActor
    func selectionWhileHeldIsDeferred() async {
        let store = StubSettingsStore()
        let applied = Box<[ShortcutBinding]>([])
        let model = makeModel(store: store, applied: applied)

        model.shortcutPressed()
        await model.select(.rightShift)

        #expect(model.binding == .rightOption, "a Dictation in flight keeps the key it started on")
        #expect(applied.value.isEmpty)
        #expect(model.pendingBinding == .rightShift)
        #expect(model.deferredMessage != nil)
        #expect(await store.stored.shortcutBinding == .rightShift)

        await model.shortcutReleased()

        #expect(model.binding == .rightShift)
        #expect(applied.value == [.rightShift])
        #expect(model.pendingBinding == nil)
    }

    @Test("choosing the key that is already bound changes nothing")
    @MainActor
    func selectingTheSameKeyIsANoOp() async {
        let store = StubSettingsStore()
        let applied = Box<[ShortcutBinding]>([])
        let model = makeModel(store: store, applied: applied)

        await model.select(.rightOption)

        #expect(applied.value.isEmpty)
        #expect(await store.writeCount == 0)
    }

    @Test("the model adopts the persisted key at launch")
    @MainActor
    func loadAdoptsPersistedBinding() async {
        let store = StubSettingsStore(
            .init(
                shortcutBinding: .leftShift,
                microphoneDeviceIdentifier: nil,
                onboarding: .initial
            ))
        let model = makeModel(store: store)

        await model.load()

        #expect(model.binding == .leftShift)
    }

    @Test("reloading settings does not drop a choice the held key is still waiting on")
    @MainActor
    func loadKeepsADeferredChoice() async {
        let store = StubSettingsStore()
        let applied = Box<[ShortcutBinding]>([])
        let model = makeModel(store: store, applied: applied)

        model.shortcutPressed()
        await model.select(.leftShift)
        await model.load()

        #expect(model.binding == .rightOption, "the monitor is still listening for the old key")
        #expect(model.pendingBinding == .leftShift)

        await model.shortcutReleased()

        #expect(model.binding == .leftShift)
        #expect(applied.value == [.leftShift])
    }

    @Test("a release with nothing pending leaves the binding alone")
    @MainActor
    func releaseWithoutPendingKeepsBinding() async {
        let applied = Box<[ShortcutBinding]>([])
        let model = makeModel(applied: applied)

        model.shortcutPressed()
        await model.shortcutReleased()

        #expect(model.binding == .rightOption)
        #expect(applied.value.isEmpty)
        #expect(model.isHeld == false)
    }
}
