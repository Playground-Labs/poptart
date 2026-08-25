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

/// A listen-only event tap for the default Right Option press-and-hold gesture.
public final class RightOptionShortcutMonitor: @unchecked Sendable {
  public typealias SignalHandler = @Sendable (ShortcutSignal) -> Void

  private let permission: any KeyboardMonitoringPermission
  private let handler: SignalHandler
  private let lock = NSLock()
  private var policy = RightOptionShortcutPolicy()
  private var tap: CFMachPort?
  private var runLoopSource: CFRunLoopSource?

  public init(
    permission: any KeyboardMonitoringPermission = SystemKeyboardMonitoringPermission(),
    handler: @escaping SignalHandler
  ) {
    self.permission = permission
    self.handler = handler
  }

  deinit {
    stop()
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
        callback: rightOptionEventTapCallback,
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

  /// Rearms the next gesture after the five-minute safety stop or another lost key-up recovery.
  public func rearmAfterForcedStop() {
    lock.withLock { _ = policy.reset() }
  }

  fileprivate func receive(type: CGEventType, event: CGEvent) {
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
      isDown: CGEventSource.keyState(
        .combinedSessionState,
        key: CGKeyCode(RightOptionShortcutPolicy.rightOptionKeyCode)
      )
    )
    lock.unlock()
    if let signal { handler(signal) }
  }
}

private let rightOptionEventTapCallback: CGEventTapCallBack = { _, type, event, userInfo in
  guard let userInfo else { return Unmanaged.passUnretained(event) }
  let monitor = Unmanaged<RightOptionShortcutMonitor>.fromOpaque(userInfo).takeUnretainedValue()
  monitor.receive(type: type, event: event)
  return Unmanaged.passUnretained(event)
}
