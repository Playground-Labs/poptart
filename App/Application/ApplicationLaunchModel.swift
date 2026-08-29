import Foundation
import Observation

public enum RequiredPermission: String, Equatable, Sendable {
    case microphone
    case accessibility
    case keyboardMonitoring

    public var displayName: String {
        switch self {
        case .microphone: "Microphone access"
        case .accessibility: "Accessibility access"
        case .keyboardMonitoring: "Input Monitoring"
        }
    }
}

public enum ApplicationLaunchStatus: Equatable, Sendable {
    case notStarted
    case modelPackRequired
    case permissionRequired(RequiredPermission)
    case starting
    case ready
    case failed(String)

    public var message: String {
        switch self {
        case .notStarted: "Poptart has not started the local models yet."
        case .modelPackRequired: "Install the verified Model Pack to start dictating."
        case .permissionRequired(let permission): "Allow \(permission.displayName)."
        case .starting: "Loading the local models…"
        case .ready: "Ready."
        case .failed(let message): message
        }
    }

    public var isReady: Bool { self == .ready }
}

/// Decides what the application can do at launch: whether a verified pack is present, which
/// permission is missing, and whether the runtime started. It performs no work of its own beyond
/// asking the injected runtime to start.
@MainActor
@Observable
public final class ApplicationLaunchModel {
    public typealias RuntimeStart = @MainActor (ActiveApplicationModelPack) async throws -> Void

    public private(set) var status: ApplicationLaunchStatus = .notStarted
    public private(set) var activePack: ActiveApplicationModelPack?

    private let modelPacks: any ActiveModelPackProviding
    private let startRuntime: RuntimeStart

    public init(modelPacks: any ActiveModelPackProviding, startRuntime: @escaping RuntimeStart) {
        self.modelPacks = modelPacks
        self.startRuntime = startRuntime
    }

    /// Starts the runtime once. Calling it again while it is starting, or after it is ready, does
    /// nothing; use ``restart()`` after granting a permission or installing a pack.
    public func start() async {
        guard status != .starting, status != .ready else { return }
        status = .starting
        let located: ActiveApplicationModelPack?
        do {
            located = try await modelPacks.activePack()
        } catch {
            activePack = nil
            status = .failed("The verified Model Pack registry is unreadable. Use Repair Model Pack.")
            return
        }
        guard let pack = located else {
            activePack = nil
            status = .modelPackRequired
            return
        }
        activePack = pack
        do {
            try await startRuntime(pack)
            status = .ready
        } catch RuntimeAssemblyError.microphonePermissionRequired {
            status = .permissionRequired(.microphone)
        } catch RuntimeAssemblyError.accessibilityPermissionRequired {
            status = .permissionRequired(.accessibility)
        } catch RuntimeAssemblyError.shortcutPermissionRequired {
            status = .permissionRequired(.keyboardMonitoring)
        } catch RuntimeAssemblyError.shortcutUnavailable {
            status = .failed("macOS would not give Poptart a keyboard event tap for the shortcut.")
        } catch RuntimeAssemblyError.modelPackMissing {
            status = .modelPackRequired
        } catch {
            status = .failed("The local models did not start. Use Repair Model Pack and try again.")
        }
    }

    public func restart() async {
        status = .notStarted
        await start()
    }
}
