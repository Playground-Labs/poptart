import Foundation
import SystemIntegration

/// The application-level state that is not sensitive and not owned by a package store: the chosen
/// Dictation shortcut, the chosen microphone, and how far onboarding has progressed. Transcripts,
/// Personal Vocabulary, and Dictation Records live in the encrypted `Persistence` stores instead.
public struct AppSettings: Equatable, Sendable {
    public var shortcutBinding: ShortcutBinding
    public var microphoneDeviceIdentifier: String?
    public var onboarding: OnboardingProgress

    public static let defaults = AppSettings(
        shortcutBinding: .rightOption,
        microphoneDeviceIdentifier: nil,
        onboarding: .initial
    )

    public init(
        shortcutBinding: ShortcutBinding,
        microphoneDeviceIdentifier: String?,
        onboarding: OnboardingProgress
    ) {
        self.shortcutBinding = shortcutBinding
        self.microphoneDeviceIdentifier = microphoneDeviceIdentifier
        self.onboarding = onboarding
    }
}

public protocol AppSettingsStoring: Sendable {
    func settings() async -> AppSettings
    func setShortcutBinding(_ binding: ShortcutBinding) async throws
    func setMicrophoneDeviceIdentifier(_ identifier: String?) async throws
    func setOnboardingProgress(_ progress: OnboardingProgress) async throws
}

/// Stores application settings as plain JSON beside the encrypted stores. The contents are not
/// sensitive, so they are readable without the installation key; a file that cannot be read falls
/// back to the documented defaults rather than blocking startup.
public actor AppSettingsStore: AppSettingsStoring {
    private struct Stored: Codable {
        var shortcutBinding: String?
        var microphoneDeviceIdentifier: String?
        var onboarding: OnboardingProgress?
    }

    private let fileURL: URL
    private var cached: AppSettings?

    public init(directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        self.fileURL = directory.appendingPathComponent("Settings.json")
    }

    public func settings() -> AppSettings {
        if let cached { return cached }
        let loaded = load()
        cached = loaded
        return loaded
    }

    public func setShortcutBinding(_ binding: ShortcutBinding) throws {
        var settings = settings()
        settings.shortcutBinding = binding
        try write(settings)
    }

    public func setMicrophoneDeviceIdentifier(_ identifier: String?) throws {
        var settings = settings()
        settings.microphoneDeviceIdentifier = identifier
        try write(settings)
    }

    public func setOnboardingProgress(_ progress: OnboardingProgress) throws {
        var settings = settings()
        settings.onboarding = progress
        try write(settings)
    }

    private func load() -> AppSettings {
        guard let data = try? Data(contentsOf: fileURL),
              let stored = try? JSONDecoder().decode(Stored.self, from: data)
        else { return .defaults }
        // An identifier this build no longer supports must not strand the person without a
        // shortcut, so it falls back to the default binding.
        let binding = stored.shortcutBinding
            .flatMap { try? ShortcutBinding(identifier: $0) } ?? .rightOption
        return .init(
            shortcutBinding: binding,
            microphoneDeviceIdentifier: stored.microphoneDeviceIdentifier,
            onboarding: stored.onboarding ?? .initial
        )
    }

    private func write(_ settings: AppSettings) throws {
        let stored = Stored(
            shortcutBinding: settings.shortcutBinding.identifier,
            microphoneDeviceIdentifier: settings.microphoneDeviceIdentifier,
            onboarding: settings.onboarding
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        try encoder.encode(stored).write(to: fileURL, options: [.atomic])
        cached = settings
    }
}
