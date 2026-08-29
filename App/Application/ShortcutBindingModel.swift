import Foundation
import Observation
import SystemIntegration

/// Owns the one Dictation shortcut: which key is bound, how a new choice reaches the live monitor,
/// and how the choice is persisted.
///
/// A swap made while the key is held would end the gesture underneath an active Dictation, so a
/// choice made mid-press waits for the release before it is applied.
@MainActor
@Observable
public final class ShortcutBindingModel {
    public private(set) var binding: ShortcutBinding
    /// A choice waiting for the held key to be released.
    public private(set) var pendingBinding: ShortcutBinding?
    public private(set) var isHeld = false

    public var options: [ShortcutBinding] { ShortcutBinding.allCases }

    public var deferredMessage: String? {
        pendingBinding.map { "\($0.displayName) takes effect when you release the current key." }
    }

    private let settings: any AppSettingsStoring
    private var apply: @Sendable (ShortcutBinding) -> Void

    public init(
        binding: ShortcutBinding,
        settings: any AppSettingsStoring,
        apply: @escaping @Sendable (ShortcutBinding) -> Void = { _ in }
    ) {
        self.binding = binding
        self.settings = settings
        self.apply = apply
    }

    /// Adopts the persisted choice. The runtime starts the monitor on this same binding.
    ///
    /// A choice already waiting for a held key keeps the model and the live monitor in step, so it
    /// is left alone: adopting the persisted value here would claim a key the monitor is not
    /// listening for yet.
    public func load() async {
        let persisted = await settings.settings().shortcutBinding
        guard pendingBinding == nil else { return }
        binding = persisted
    }

    /// Points the model at the live monitor once the runtime exists.
    public func connect(_ apply: @escaping @Sendable (ShortcutBinding) -> Void) {
        self.apply = apply
    }

    /// Chooses the key that starts a Dictation. The choice is persisted immediately; it reaches the
    /// live monitor once no key is held.
    public func select(_ binding: ShortcutBinding) async {
        guard binding != self.binding else {
            pendingBinding = nil
            return
        }
        try? await settings.setShortcutBinding(binding)
        guard !isHeld else {
            pendingBinding = binding
            return
        }
        pendingBinding = nil
        self.binding = binding
        apply(binding)
    }

    public func shortcutPressed() {
        isHeld = true
    }

    public func shortcutReleased() async {
        isHeld = false
        guard let pendingBinding else { return }
        self.pendingBinding = nil
        binding = pendingBinding
        apply(pendingBinding)
    }
}
