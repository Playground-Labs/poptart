import Foundation

public enum CleanupEditCategory: String, Codable, Equatable, Sendable {
  case correction
  case punctuation
  case capitalization
  case filler
  case repetition
  case vocabulary
}

public struct CleanupEdit: Codable, Equatable, Sendable {
  public let startSpan: Int
  public let endSpan: Int
  public let replacement: String
  public let category: CleanupEditCategory

  public init(
    startSpan: Int,
    endSpan: Int,
    replacement: String,
    category: CleanupEditCategory
  ) {
    self.startSpan = startSpan
    self.endSpan = endSpan
    self.replacement = replacement
    self.category = category
  }

  enum CodingKeys: String, CodingKey {
    case startSpan = "s"
    case endSpan = "e"
    case replacement = "r"
    case category = "c"
  }
}

public struct CleanupEditPlan: Codable, Equatable, Sendable {
  public static let currentVersion = 1

  public let version: Int
  public let edits: [CleanupEdit]

  public init(version: Int = currentVersion, edits: [CleanupEdit]) {
    self.version = version
    self.edits = edits
  }

  enum CodingKeys: String, CodingKey {
    case version = "v"
    case edits = "e"
  }
}

public enum CleanupEditPlanError: Error, Equatable, Sendable {
  case exceedsByteLimit
  case incomplete
  case malformed
  case unsupportedVersion
}

/// Accepts model output in chunks but only releases a complete, bounded JSON plan terminated by
/// the protocol stop marker. Prose, markdown fences, unknown fields, and trailing bytes fail closed.
public struct BoundedEditPlanParser: Sendable {
  private var buffer = ""
  private let maximumBytes: Int
  private let stopMarker: String

  public init(maximumBytes: Int, stopMarker: String = CleanupPrompt.stopMarker) {
    precondition(maximumBytes > 0)
    self.maximumBytes = maximumBytes
    self.stopMarker = stopMarker
  }

  public mutating func append(_ chunk: String) throws -> CleanupEditPlan? {
    guard buffer.utf8.count + chunk.utf8.count <= maximumBytes + stopMarker.utf8.count else {
      throw CleanupEditPlanError.exceedsByteLimit
    }
    buffer += chunk
    guard let markerRange = buffer.range(of: stopMarker) else { return nil }
    guard markerRange.upperBound == buffer.endIndex else { throw CleanupEditPlanError.malformed }
    return try decode(String(buffer[..<markerRange.lowerBound]))
  }

  private func decode(_ json: String) throws -> CleanupEditPlan {
    guard let data = json.data(using: .utf8), data.count <= maximumBytes else {
      throw CleanupEditPlanError.exceedsByteLimit
    }
    guard !Self.hasDuplicateObjectKeys(data),
      let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      Set(root.keys) == ["v", "e"],
      let rawEdits = root["e"] as? [[String: Any]],
      rawEdits.allSatisfy({ Set($0.keys) == ["s", "e", "r", "c"] })
    else { throw CleanupEditPlanError.malformed }
    let plan: CleanupEditPlan
    do {
      plan = try JSONDecoder().decode(CleanupEditPlan.self, from: data)
    } catch {
      throw CleanupEditPlanError.malformed
    }
    guard plan.version == CleanupEditPlan.currentVersion else {
      throw CleanupEditPlanError.unsupportedVersion
    }
    return plan
  }

  private static func hasDuplicateObjectKeys(_ data: Data) -> Bool {
    enum Container {
      case object(Set<String>)
      case array
    }

    let bytes = Array(data)
    var stack: [Container] = []
    var index = 0
    while index < bytes.count {
      switch bytes[index] {
      case 0x7B:  // {
        stack.append(.object([]))
        index += 1
      case 0x5B:  // [
        stack.append(.array)
        index += 1
      case 0x7D, 0x5D:  // } or ]
        if !stack.isEmpty { stack.removeLast() }
        index += 1
      case 0x22:  // string
        let start = index
        index += 1
        var escaped = false
        while index < bytes.count {
          let byte = bytes[index]
          if escaped {
            escaped = false
          } else if byte == 0x5C {
            escaped = true
          } else if byte == 0x22 {
            break
          }
          index += 1
        }
        guard index < bytes.count else { return false }
        let end = index
        var lookahead = end + 1
        while lookahead < bytes.count, [0x20, 0x09, 0x0A, 0x0D].contains(bytes[lookahead]) {
          lookahead += 1
        }
        if lookahead < bytes.count,
          bytes[lookahead] == 0x3A,
          case .object(var keys)? = stack.last,
          let key = try? JSONDecoder().decode(String.self, from: Data(bytes[start...end]))
        {
          if keys.contains(key) { return true }
          keys.insert(key)
          stack[stack.count - 1] = .object(keys)
        }
        index = end + 1
      default:
        index += 1
      }
    }
    return false
  }
}
