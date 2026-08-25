import Foundation
import Testing

@testable import ModelRuntime

@Suite("Warm model residency")
struct ModelResidencyTests {
  @Test(
    "Models stay warm until native memory pressure releases Cleanup, then Recording prewarms it")
  func pressureDrivenLifecycle() async throws {
    let loader = FakeModelLoader()
    let controller = ModelResidencyController(loader: loader)

    try await controller.keepWarm()
    await controller.handleMemoryPressure(.normal)
    #expect(await controller.isResident(.recognition))
    #expect(await controller.isResident(.cleanup))
    #expect(await loader.events() == [.load(.recognition), .load(.cleanup)])

    await controller.handleMemoryPressure(.warning)
    await controller.handleMemoryPressure(.critical)
    #expect(await controller.isResident(.recognition))
    #expect(!(await controller.isResident(.cleanup)))
    #expect(await loader.events().last == .unload(.cleanup))
    #expect(await loader.events().filter { $0 == .unload(.cleanup) }.count == 1)

    try await controller.recordingDidBegin()
    #expect(await controller.isResident(.cleanup))
    #expect(await loader.events().last == .load(.cleanup))
  }
}

private enum LoaderEvent: Equatable, Sendable {
  case load(ModelRole)
  case unload(ModelRole)
}

private actor FakeModelLoader: ManagedModelLoading {
  private var recordedEvents: [LoaderEvent] = []

  func load(_ role: ModelRole) async throws { recordedEvents.append(.load(role)) }
  func unload(_ role: ModelRole) async { recordedEvents.append(.unload(role)) }
  func events() -> [LoaderEvent] { recordedEvents }
}
