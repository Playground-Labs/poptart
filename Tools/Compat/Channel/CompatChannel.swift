import Foundation

/// Local-only, file-backed command channel between the compatibility host and driver.
///
/// The transport is deliberately a watched directory: no sockets, no ports, no network. Every
/// file is written to a temporary sibling and renamed into place so a reader can never observe a
/// partially written payload.
public enum CompatCommand: String, Codable, Sendable {
  /// Bring the host window to the front and make it the frontmost application.
  case activate
  /// Restore every control to its seed value and clear the first responder.
  case reset
  /// Make one control the focused control (AppKit first responder, or DOM focus for web controls).
  case focus
  /// Drop the window's first responder so keystrokes reach no control.
  case blur
  /// Set the selected range inside one control.
  case setSelection
  /// Read the ground-truth value of every control.
  case snapshot
  /// Terminate the host.
  case quit
}

public struct CompatRequest: Codable, Sendable {
  public var sequence: Int
  public var command: CompatCommand
  public var control: String?
  public var location: Int?
  public var length: Int?

  public init(
    sequence: Int,
    command: CompatCommand,
    control: String? = nil,
    location: Int? = nil,
    length: Int? = nil
  ) {
    self.sequence = sequence
    self.command = command
    self.control = control
    self.location = location
    self.length = length
  }
}

/// Accessibility screen coordinates: origin at the top-left of the primary display.
public struct CompatRect: Codable, Sendable, Equatable {
  public var x: Double
  public var y: Double
  public var width: Double
  public var height: Double

  public init(x: Double, y: Double, width: Double, height: Double) {
    self.x = x
    self.y = y
    self.width = width
    self.height = height
  }
}

public struct CompatControlSnapshot: Codable, Sendable, Equatable {
  public var identifier: String
  /// Ground-truth value read from the control's own model, not through Accessibility.
  public var value: String?
  public var isFocused: Bool
  /// Number of Accessibility value reads observed by the host's instrumented subclasses.
  /// `nil` means the control is not instrumented (the WebKit controls).
  public var accessibilityValueReads: Int?
  public var frame: CompatRect?

  public init(
    identifier: String,
    value: String?,
    isFocused: Bool,
    accessibilityValueReads: Int?,
    frame: CompatRect?
  ) {
    self.identifier = identifier
    self.value = value
    self.isFocused = isFocused
    self.accessibilityValueReads = accessibilityValueReads
    self.frame = frame
  }
}

public struct CompatResponse: Codable, Sendable {
  public var sequence: Int
  public var ok: Bool
  public var error: String?
  /// The host's own view of which control currently holds focus.
  public var focusedControl: String?
  public var controls: [CompatControlSnapshot]?

  public init(
    sequence: Int,
    ok: Bool,
    error: String? = nil,
    focusedControl: String? = nil,
    controls: [CompatControlSnapshot]? = nil
  ) {
    self.sequence = sequence
    self.ok = ok
    self.error = error
    self.focusedControl = focusedControl
    self.controls = controls
  }
}

public struct CompatHostReady: Codable, Sendable {
  public var processIdentifier: Int32
  public var bundleIdentifier: String?
  public var controls: [String]

  public init(processIdentifier: Int32, bundleIdentifier: String?, controls: [String]) {
    self.processIdentifier = processIdentifier
    self.bundleIdentifier = bundleIdentifier
    self.controls = controls
  }
}

public struct CompatChannelPaths: Sendable {
  public let root: URL
  public let requests: URL
  public let responses: URL
  public let ready: URL

  public init(root: URL) {
    self.root = root.standardizedFileURL
    self.requests = self.root.appendingPathComponent("requests", isDirectory: true)
    self.responses = self.root.appendingPathComponent("responses", isDirectory: true)
    self.ready = self.root.appendingPathComponent("host-ready.json", isDirectory: false)
  }

  public func createDirectories() throws {
    for directory in [root, requests, responses] {
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
  }

  public func request(_ sequence: Int) -> URL {
    requests.appendingPathComponent("\(sequence).json", isDirectory: false)
  }

  public func response(_ sequence: Int) -> URL {
    responses.appendingPathComponent("\(sequence).json", isDirectory: false)
  }
}

public enum CompatChannelIO {
  public static func write(_ value: some Encodable, to url: URL) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let data = try encoder.encode(value)
    let temporary = url.deletingLastPathComponent()
      .appendingPathComponent(".\(UUID().uuidString).tmp", isDirectory: false)
    try data.write(to: temporary, options: .atomic)
    // Rename is atomic within a volume, so a reader sees either nothing or the whole payload.
    _ = try FileManager.default.replaceItemAt(url, withItemAt: temporary)
  }

  public static func read<T: Decodable>(_ type: T.Type, from url: URL) throws -> T {
    try JSONDecoder().decode(type, from: Data(contentsOf: url))
  }
}
