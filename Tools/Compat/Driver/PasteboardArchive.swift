import AppKit
import Foundation

/// A full copy of the general pasteboard, used both to leave the operator's clipboard untouched
/// and to seed a known multi-representation payload for the restoration check.
struct PasteboardArchive {
  let items: [[String: Data]]

  static func capture() -> PasteboardArchive {
    let items = NSPasteboard.general.pasteboardItems ?? []
    return PasteboardArchive(
      items: items.map { item in
        var values: [String: Data] = [:]
        for type in item.types {
          if let data = item.data(forType: type) { values[type.rawValue] = data }
        }
        return values
      })
  }

  @discardableResult
  func restore() -> Bool {
    let pasteboard = NSPasteboard.general
    pasteboard.clearContents()
    guard !items.isEmpty else { return true }
    let objects = items.map { values -> NSPasteboardItem in
      let item = NSPasteboardItem()
      for (rawType, data) in values {
        item.setData(data, forType: .init(rawValue: rawType))
      }
      return item
    }
    return pasteboard.writeObjects(objects)
  }
}

enum ClipboardSeed {
  static let markerType = NSPasteboard.PasteboardType("labs.playground.poptart.compat.marker")
  static let string = "COMPAT CLIPBOARD SEED ✓"
  static let markerData = Data("COMPAT-MARKER-PAYLOAD".utf8)

  /// Writes a two-representation item so restoration is checked for more than the plain string.
  @discardableResult
  static func write() -> Int {
    let pasteboard = NSPasteboard.general
    pasteboard.clearContents()
    let item = NSPasteboardItem()
    item.setString(string, forType: .string)
    item.setData(markerData, forType: markerType)
    _ = pasteboard.writeObjects([item])
    return pasteboard.changeCount
  }

  static var stringSurvived: Bool {
    NSPasteboard.general.string(forType: .string) == string
  }

  static var markerSurvived: Bool {
    NSPasteboard.general.data(forType: markerType) == markerData
  }
}

/// Writes a promised string to the pasteboard so the coverage probe can tell "the control refused
/// the paste" apart from "the synthesised Cmd-V never reached anything".
///
/// The provider callback can arrive on a framework thread, so the flag is lock protected.
final class ProbePasteboardWriter: NSObject, NSPasteboardItemDataProvider, @unchecked Sendable {
  private let text: String
  private let lock = NSLock()
  private var read = false

  init(text: String) {
    self.text = text
  }

  var wasRead: Bool {
    lock.withLock { read }
  }

  @discardableResult
  func write() -> Bool {
    let pasteboard = NSPasteboard.general
    pasteboard.clearContents()
    let item = NSPasteboardItem()
    item.setDataProvider(self, forTypes: [.string])
    return pasteboard.writeObjects([item])
  }

  func pasteboard(
    _ pasteboard: NSPasteboard?,
    item: NSPasteboardItem,
    provideDataForType type: NSPasteboard.PasteboardType
  ) {
    lock.withLock { read = true }
    item.setString(text, forType: type)
  }
}
