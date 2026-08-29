import CoreGraphics
import Foundation

public protocol KeyboardMonitoringPermission: Sendable {
  func isGranted() -> Bool
  func request() -> Bool
}

public struct SystemKeyboardMonitoringPermission: KeyboardMonitoringPermission {
  public init() {}

  public func isGranted() -> Bool {
    CGPreflightListenEventAccess()
  }

  public func request() -> Bool {
    CGRequestListenEventAccess()
  }
}

public enum ShortcutMonitorStartResult: Equatable, Sendable {
  case started
  case alreadyStarted
  case permissionDenied
  case eventTapUnavailable
}

/// A listen-only event tap for the press-and-hold Dictation shortcut, bound by
/// default to Right Option and rebindable while the app runs.
public final class DictationShortcutMonitor: @unchecked Sendable {
  public typealias SignalHandler = @Sendable (ShortcutSignal) -> Void

  private let permission: any KeyboardMonitoringPermission
  private let handler: SignalHandler
  private let lock = NSLock()
  /// Guarded by `lock`; package-visible only so tests can stage a held gesture.
  var policy: DictationShortcutPolicy
  private var tap: CFMachPort?
  private var runLoopSource: CFRunLoopSource?

  public init(
    binding: ShortcutBinding = .rightOption,
    permission: any KeyboardMonitoringPermission = SystemKeyboardMonitoringPermission(),
    handler: @escaping SignalHandler
  ) {
    policy = DictationShortcutPolicy(binding: binding)
    self.permission = permission
    self.handler = handler
  }

  deinit {
    stop()
  }

  /// The key currently held to dictate.
  public var binding: ShortcutBinding {
    lock.lock()
    defer { lock.unlock() }
    return policy.binding
  }

  @discardableResult
  public func start(requestPermission: Bool = false) -> ShortcutMonitorStartResult {
    lock.lock()
    defer { lock.unlock() }
    guard tap == nil else { return .alreadyStarted }

    let granted = permission.isGranted() || (requestPermission && permission.request())
    guard granted else { return .permissionDenied }

    let mask = CGEventMask(1) << CGEventType.flagsChanged.rawValue
    let userInfo = Unmanaged.passUnretained(self).toOpaque()
    guard
      let eventTap = CGEvent.tapCreate(
        tap: .cgSessionEventTap,
        place: .headInsertEventTap,
        options: .listenOnly,
        eventsOfInterest: mask,
        callback: dictationShortcutEventTapCallback,
        userInfo: userInfo
      )
    else { return .eventTapUnavailable }

    let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, eventTap, 0)
    CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
    CGEvent.tapEnable(tap: eventTap, enable: true)
    tap = eventTap
    runLoopSource = source
    return .started
  }

  public func stop() {
    let release: ShortcutSignal?
    lock.lock()
    if let source = runLoopSource {
      CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
    }
    if let tap {
      CGEvent.tapEnable(tap: tap, enable: false)
    }
    self.tap = nil
    runLoopSource = nil
    release = policy.reset()
    lock.unlock()
    if let release { handler(release) }
  }

  /// Moves the shortcut to another key without restarting the tap. The next
  /// press uses the new key; a gesture already in flight is released first.
  public func rebind(to binding: ShortcutBinding) {
    let release: ShortcutSignal?
    lock.lock()
    release = policy.rebind(to: binding)
    lock.unlock()
    if let release { handler(release) }
  }

  func receive(type: CGEventType, event: CGEvent) {
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
      let release: ShortcutSignal?
      lock.lock()
      release = policy.reset()
      if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
      lock.unlock()
      if let release { handler(release) }
      return
    }

    guard type == .flagsChanged else { return }
    let signal: ShortcutSignal?
    lock.lock()
    signal = policy.handle(
      keyCode: event.getIntegerValueField(.keyboardEventKeycode),
      flags: event.flags
    )
    lock.unlock()
    if let signal { handler(signal) }
  }
}

private let dictationShortcutEventTapCallback: CGEventTapCallBack = { _, type, event, userInfo in
  guard let userInfo else { return Unmanaged.passUnretained(event) }
  let monitor = Unmanaged<DictationShortcutMonitor>.fromOpaque(userInfo).takeUnretainedValue()
  monitor.receive(type: type, event: event)
  return Unmanaged.passUnretained(event)
}
