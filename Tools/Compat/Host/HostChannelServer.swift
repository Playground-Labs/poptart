import AppKit
import CompatChannel
import Foundation

/// Serves the driver's commands from a watched local directory.
///
/// Requests are handled strictly one at a time and in sequence order so that a focus command can
/// never overtake the reset that was supposed to precede it.
@MainActor
final class HostChannelServer {
  private let paths: CompatChannelPaths
  private let controls: HostControls
  private var timer: Timer?
  private var busy = false
  private var handled: Set<Int> = []

  init(paths: CompatChannelPaths, controls: HostControls) {
    self.paths = paths
    self.controls = controls
  }

  func start() {
    let timer = Timer(timeInterval: 0.005, repeats: true) { [weak self] _ in
      MainActor.assumeIsolated { self?.poll() }
    }
    RunLoop.main.add(timer, forMode: .common)
    self.timer = timer
  }

  func stop() {
    timer?.invalidate()
    timer = nil
  }

  private func poll() {
    guard !busy else { return }
    let files =
      (try? FileManager.default.contentsOfDirectory(
        at: paths.requests,
        includingPropertiesForKeys: nil,
        options: [.skipsHiddenFiles]
      )) ?? []
    let pending =
      files
      .filter { $0.pathExtension == "json" }
      .compactMap { url -> (Int, URL)? in
        guard let sequence = Int(url.deletingPathExtension().lastPathComponent) else { return nil }
        return handled.contains(sequence) ? nil : (sequence, url)
      }
      .sorted { $0.0 < $1.0 }
    guard let (sequence, url) = pending.first,
      let request = try? CompatChannelIO.read(CompatRequest.self, from: url)
    else { return }
    busy = true
    handled.insert(sequence)
    Task { @MainActor in
      let response = await handle(request)
      try? CompatChannelIO.write(response, to: paths.response(sequence))
      try? FileManager.default.removeItem(at: url)
      busy = false
      if request.command == .quit {
        NSApp.terminate(nil)
      }
    }
  }

  private func handle(_ request: CompatRequest) async -> CompatResponse {
    func respond(ok: Bool, error: String? = nil) async -> CompatResponse {
      CompatResponse(
        sequence: request.sequence,
        ok: ok,
        error: error,
        focusedControl: await controls.focusedControlIdentifier(),
        controls: await controls.snapshot()
      )
    }

    switch request.command {
    case .activate:
      controls.activate()
      return await respond(ok: NSApp.isActive)
    case .reset:
      await controls.reset()
      return await respond(ok: true)
    case .blur:
      await controls.blur()
      return await respond(ok: await controls.focusedControlIdentifier() == nil)
    case .focus:
      guard let identifier = request.control else {
        return await respond(ok: false, error: "focus requires a control identifier")
      }
      controls.activate()
      let focused = await controls.focus(identifier)
      return await respond(
        ok: focused,
        error: focused ? nil : "control refused focus: \(identifier)"
      )
    case .setSelection:
      guard let identifier = request.control,
        let location = request.location,
        let length = request.length
      else {
        return await respond(ok: false, error: "setSelection requires control, location, length")
      }
      let applied = await controls.setSelection(identifier, location: location, length: length)
      return await respond(
        ok: applied,
        error: applied ? nil : "selection refused by \(identifier)"
      )
    case .snapshot:
      return await respond(ok: true)
    case .quit:
      return await respond(ok: true)
    }
  }
}
