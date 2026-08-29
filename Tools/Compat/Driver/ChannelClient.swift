import CompatChannel
import Foundation

enum ChannelError: Error, CustomStringConvertible {
  case timedOut(CompatCommand)
  case hostExited
  case hostNeverReady

  var description: String {
    switch self {
    case .timedOut(let command): "compat host did not answer command \(command.rawValue)"
    case .hostExited: "compat host exited while the matrix was running"
    case .hostNeverReady: "compat host never published its ready file"
    }
  }
}

/// Driver-side half of the local file channel.
@MainActor
final class ChannelClient {
  private let paths: CompatChannelPaths
  private var sequence = 0
  private(set) var hostProcessIdentifier: pid_t = 0
  private(set) var hostBundleIdentifier: String?

  init(paths: CompatChannelPaths) {
    self.paths = paths
  }

  func waitForHost(timeout: Duration) async throws -> CompatHostReady {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
      if let ready = try? CompatChannelIO.read(CompatHostReady.self, from: paths.ready) {
        hostProcessIdentifier = ready.processIdentifier
        hostBundleIdentifier = ready.bundleIdentifier
        return ready
      }
      try? await Task.sleep(for: .milliseconds(50))
    }
    throw ChannelError.hostNeverReady
  }

  var hostIsAlive: Bool {
    hostProcessIdentifier != 0 && kill(hostProcessIdentifier, 0) == 0
  }

  @discardableResult
  func send(
    _ command: CompatCommand,
    control: String? = nil,
    location: Int? = nil,
    length: Int? = nil,
    timeout: Duration = .seconds(20)
  ) async throws -> CompatResponse {
    sequence += 1
    let current = sequence
    let request = CompatRequest(
      sequence: current,
      command: command,
      control: control,
      location: location,
      length: length
    )
    try CompatChannelIO.write(request, to: paths.request(current))
    let responseURL = paths.response(current)
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
      if let response = try? CompatChannelIO.read(CompatResponse.self, from: responseURL) {
        try? FileManager.default.removeItem(at: responseURL)
        return response
      }
      if command != .quit, hostProcessIdentifier != 0, !hostIsAlive {
        throw ChannelError.hostExited
      }
      try? await Task.sleep(for: .milliseconds(5))
    }
    throw ChannelError.timedOut(command)
  }

  func snapshot() async throws -> [String: CompatControlSnapshot] {
    let response = try await send(.snapshot)
    return Dictionary(
      uniqueKeysWithValues: (response.controls ?? []).map { ($0.identifier, $0) })
  }

  func value(of identifier: String) async throws -> String? {
    try await snapshot()[identifier]?.value
  }
}
