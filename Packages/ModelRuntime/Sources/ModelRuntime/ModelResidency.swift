import Dispatch
import Foundation

public enum MemoryPressureLevel: Sendable {
  case normal
  case warning
  case critical
}

public protocol ManagedModelLoading: Sendable {
  func load(_ role: ModelRole) async throws
  func unload(_ role: ModelRole) async
}

/// Maintains warm models for the process lifetime. It contains no residency timer.
public actor ModelResidencyController {
  private let loader: any ManagedModelLoading
  private var resident: Set<ModelRole> = []

  public init(loader: any ManagedModelLoading) {
    self.loader = loader
  }

  public func keepWarm() async throws {
    for role in ModelRole.allCases where !resident.contains(role) {
      try await loader.load(role)
      resident.insert(role)
    }
  }

  public func recordingDidBegin() async throws {
    guard !resident.contains(.cleanup) else { return }
    try await loader.load(.cleanup)
    resident.insert(.cleanup)
  }

  public func handleMemoryPressure(_ level: MemoryPressureLevel) async {
    guard level == .warning || level == .critical, resident.contains(.cleanup) else { return }
    await loader.unload(.cleanup)
    resident.remove(.cleanup)
  }

  public func isResident(_ role: ModelRole) -> Bool { resident.contains(role) }
}

public protocol MemoryPressureMonitoring: Sendable {
  func start(_ handler: @escaping @Sendable (MemoryPressureLevel) -> Void)
  func stop()
}

/// Bridges macOS's native pressure notifications without imposing policy on the model controller.
public final class MacOSMemoryPressureMonitor: MemoryPressureMonitoring, @unchecked Sendable {
  private let lock = NSLock()
  private var source: (any DispatchSourceMemoryPressure)?

  public init() {}

  public func start(_ handler: @escaping @Sendable (MemoryPressureLevel) -> Void) {
    stop()
    let newSource = DispatchSource.makeMemoryPressureSource(
      eventMask: [.warning, .critical],
      queue: DispatchQueue(label: "labs.playground.poptart.model-memory-pressure")
    )
    lock.withLock { source = newSource }
    newSource.setEventHandler { [weak self] in
      guard let data = self?.currentPressureData() else { return }
      if data.contains(.critical) {
        handler(.critical)
      } else if data.contains(.warning) {
        handler(.warning)
      }
    }
    newSource.resume()
  }

  public func stop() {
    let oldSource = lock.withLock { () -> (any DispatchSourceMemoryPressure)? in
      defer { source = nil }
      return source
    }
    oldSource?.cancel()
  }

  private func currentPressureData() -> DispatchSource.MemoryPressureEvent? {
    lock.withLock { source?.data }
  }

  deinit { stop() }
}
