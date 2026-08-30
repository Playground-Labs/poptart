import Foundation
import SystemIntegration

extension AccessibilityTargetAccess {
  var name: String {
    switch self {
    case .direct: "direct"
    case .pasteOnly: "pasteOnly"
    case .secure: "secure"
    case .unsupported: "unsupported"
    }
  }
}

struct FocusReport: Codable {
  var hostConfirmed = false
  var accessibilityConfirmed = false
  var strategy: String?
  var matchMethod: String?
  var focusedIdentifier: String?
  var focusedRole: String?
  var focusedSubrole: String?
}

struct DeliveryReport: Codable {
  var scenario: String
  var attempted = false
  var captureOutcome = "notAttempted"
  var deliveryResult: String?
  /// Whether the mechanism actually used matches the classification: `direct` must insert through
  /// Accessibility and `pasteOnly` must insert through the clipboard. A `direct` classification
  /// that silently degrades to a paste is the exact failure this harness was built to catch.
  var mechanismMatchesClassification: Bool?
  var seedValue: String?
  var expectedValue: String?
  var hostValue: String?
  var accessibilityValue: String?
  var readBackMatch: Bool?
  var accessibilityAgreesWithHost: Bool?
  /// `AXNumberOfCharacters` and `AXSelectedTextRange` as the shipping delivery path sees them.
  /// `DirectInsertionVerification` decides whether a direct write landed from exactly these two
  /// attributes, so recording them makes a verification failure diagnosable.
  var accessibilityCharacterCountBefore: Int?
  var accessibilityCharacterCountAfter: Int?
  var accessibilitySelectionBefore: String?
  var accessibilitySelectionAfter: String?
  /// Published by the shipping delivery itself through `DeliveryEvidenceObserver`: what the
  /// direct write achieved and what the post-paste Accessibility read-back proved.
  var directInsertionOutcome: String?
  var pasteInsertionEvidence: String?
  /// True when the delivery reported an insertion that rested on the pasteboard receipt alone.
  var insertionIsUnverified: Bool?
  var notes: [String] = []
}

/// The regression evidence for the finding that a pasteboard read is not an insertion.
///
/// Run against controls measured to pull the promised pasteboard data while keeping nothing
/// (`disabledTextField`, which has no first responder at all, and `readOnlyTextView`). Everything
/// here is produced by shipping code: the shipping capture, the shipping
/// `ClipboardPasteCoordinator`, and the shipping `PasteInsertionConfirmation`.
struct InsertionClaimProbeReport: Codable {
  var attempted = false
  var focusEstablished = false
  /// Gate one: the shipping capture refuses the control, so no delivery is reachable for it.
  var captureRefused: Bool?
  var captureOutcome: String?
  /// The precondition that makes this probe worth anything: the pasteboard promise really was
  /// pulled. If it was not, the dangerous case was not reproduced and nothing was proved.
  var promisedTextWasRead: Bool?
  var pasteboardOutcome: String?
  var pasteAttempts: [String] = []
  var stateBefore: String?
  var stateAfter: String?
  /// Gate two: what the shipping Accessibility read-back concluded.
  var insertionEvidence: String?
  var composedDeliveryResult: String?
  /// True when the pasteboard receipt and the read-back composed into an insertion claim anyway.
  /// This is the regression, and it is judged independently of the capture gate so that a revert
  /// of the read-back cannot hide behind the classifier refusing the control.
  var wouldClaimInsertion: Bool?
  var valueBefore: String?
  var valueAfter: String?
  var controlAcceptedText: Bool?
  var clipboardRestored: Bool?
  var collateralChanges: [String] = []
}

struct ClipboardReport: Codable {
  var mode = "notApplicable"
  var stringRestored: Bool?
  var markerRestored: Bool?
  var changeCountBefore: Int?
  var changeCountAfter: Int?
  var ok = true
}

struct PasteProbeReport: Codable {
  var attempted = false
  var skippedReason: String?
  /// True when something pulled the promised string off the pasteboard. Note that this is a weaker
  /// signal than it looks: the harness has observed reads on controls that refused the paste, so
  /// it is recorded as evidence rather than used as the acceptance test.
  var clipboardWasRead: Bool?
  var focusEstablished = false
  /// Acceptance is "the control took the paste", measured as a change in its own value. Some
  /// controls (a token field) transform the pasted text rather than storing it verbatim, which is
  /// still acceptance for the purpose of the product definition.
  var accepted: Bool?
  var pastedVerbatim: Bool?
  var valueBefore: String?
  var valueAfter: String?
  var collateralChanges: [String] = []
  var clipboardRestored: Bool?
}

/// Evidence for why a `direct` classification did or did not hold: the harness performs the same
/// `AXSelectedText` write the shipping delivery performs and records whether the control moved.
struct DirectWriteProbeReport: Codable {
  var attempted = false
  var accessibilityResultCode: Int32?
  var valueBefore: String?
  var valueAfter: String?
  var valueChanged: Bool?
  var selectionBefore: String?
  var selectionAfter: String?
}

struct SecureReport: Codable {
  var captureRefused = false
  var deliveryRefused = false
  var valueUnchanged = false
  var pasteboardUntouched = false
  var instrumented = false
  var accessibilityValueReadsDuringCapture: Int?
  var note: String?
}

struct ControlResult: Encodable {
  var controlClass: String
  var identifier: String
  var expectedAccess: [String]
  var actualAccess = "notMeasured"
  var classificationSource = "notMeasured"
  var serviceCaptureOutcome = "notAttempted"
  var accessibilityRole: String?
  var accessibilitySubrole: String?
  var accessibilityEnabled: Bool?
  var selectedTextSettable: Bool?
  var valueSettable: Bool?
  /// Whether the element implements `AXDOMIdentifier`. This is the signal the shipping classifier
  /// uses to demote web-hosted controls off the direct path, so it is measured on every control:
  /// the demotion is only safe while no native control carries it.
  var implementsDOMIdentifier: Bool?
  var domIdentifierValue: String?
  var expectedWebHosted: Bool?
  var focus = FocusReport()
  var caretInsertion: DeliveryReport?
  var selectionReplacement: DeliveryReport?
  var clipboard: ClipboardReport?
  var standardPasteProbe: PasteProbeReport?
  var directWriteProbe: DirectWriteProbeReport?
  var insertionClaimProbe: InsertionClaimProbeReport?
  var secure: SecureReport?
  var coverageGap = false
  var coverageGapDetail: String?
  var failures: [String] = []

  var status: String { failures.isEmpty ? "pass" : "fail" }

  enum CodingKeys: String, CodingKey {
    case controlClass, identifier, expectedAccess, actualAccess, classificationSource
    case serviceCaptureOutcome, accessibilityRole
    case accessibilitySubrole, accessibilityEnabled, selectedTextSettable, valueSettable
    case implementsDOMIdentifier, domIdentifierValue, expectedWebHosted
    case focus, caretInsertion, selectionReplacement, clipboard, standardPasteProbe
    case directWriteProbe, insertionClaimProbe, secure
    case coverageGap, coverageGapDetail, failures, status
  }

  func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(controlClass, forKey: .controlClass)
    try container.encode(identifier, forKey: .identifier)
    try container.encode(expectedAccess, forKey: .expectedAccess)
    try container.encode(actualAccess, forKey: .actualAccess)
    try container.encode(classificationSource, forKey: .classificationSource)
    try container.encode(serviceCaptureOutcome, forKey: .serviceCaptureOutcome)
    try container.encodeIfPresent(accessibilityRole, forKey: .accessibilityRole)
    try container.encodeIfPresent(accessibilitySubrole, forKey: .accessibilitySubrole)
    try container.encodeIfPresent(accessibilityEnabled, forKey: .accessibilityEnabled)
    try container.encodeIfPresent(selectedTextSettable, forKey: .selectedTextSettable)
    try container.encodeIfPresent(valueSettable, forKey: .valueSettable)
    try container.encodeIfPresent(implementsDOMIdentifier, forKey: .implementsDOMIdentifier)
    try container.encodeIfPresent(domIdentifierValue, forKey: .domIdentifierValue)
    try container.encodeIfPresent(expectedWebHosted, forKey: .expectedWebHosted)
    try container.encode(focus, forKey: .focus)
    try container.encodeIfPresent(caretInsertion, forKey: .caretInsertion)
    try container.encodeIfPresent(selectionReplacement, forKey: .selectionReplacement)
    try container.encodeIfPresent(clipboard, forKey: .clipboard)
    try container.encodeIfPresent(standardPasteProbe, forKey: .standardPasteProbe)
    try container.encodeIfPresent(directWriteProbe, forKey: .directWriteProbe)
    try container.encodeIfPresent(insertionClaimProbe, forKey: .insertionClaimProbe)
    try container.encodeIfPresent(secure, forKey: .secure)
    try container.encode(coverageGap, forKey: .coverageGap)
    try container.encodeIfPresent(coverageGapDetail, forKey: .coverageGapDetail)
    try container.encode(failures, forKey: .failures)
    try container.encode(status, forKey: .status)
  }
}

struct CalibrationReport: Codable {
  var instrumentedControlsReadCounted = false
  var secureControlReadCounted = false
  /// A control that is known to accept Cmd-V must accept it, otherwise every "refused" verdict in
  /// the coverage probe would be a false negative and no coverage gap could ever be detected.
  var standardPasteReachesControls = false
  /// The instrumented `plainTextField` and the uninstrumented `borderedTextField` must classify
  /// and deliver identically, otherwise the read counters are changing what is being measured.
  var instrumentationIsTransparent: Bool?
  var detail: String?
  var pasteSentinelDetail: String?
  var transparencyDetail: String?

  var ok: Bool {
    instrumentedControlsReadCounted && secureControlReadCounted && standardPasteReachesControls
      && instrumentationIsTransparent != false
  }
}

struct CompatReport: Encodable {
  var schemaVersion = 1
  var generatedAt: String
  var hostBundleIdentifier: String?
  var hostProcessIdentifier: Int32
  var payload: String
  var calibration: CalibrationReport
  var results: [ControlResult]

  var failedResults: [ControlResult] { results.filter { $0.status == "fail" } }
  var coverageGaps: [ControlResult] { results.filter(\.coverageGap) }
  var passed: Bool { failedResults.isEmpty && coverageGaps.isEmpty && calibration.ok }

  enum CodingKeys: String, CodingKey {
    case schemaVersion, generatedAt, hostBundleIdentifier, hostProcessIdentifier, payload
    case calibration, results, summary
  }

  func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(schemaVersion, forKey: .schemaVersion)
    try container.encode(generatedAt, forKey: .generatedAt)
    try container.encodeIfPresent(hostBundleIdentifier, forKey: .hostBundleIdentifier)
    try container.encode(hostProcessIdentifier, forKey: .hostProcessIdentifier)
    try container.encode(payload, forKey: .payload)
    try container.encode(calibration, forKey: .calibration)
    try container.encode(results, forKey: .results)
    try container.encode(
      [
        "total": results.count,
        "passed": results.count - failedResults.count,
        "failed": failedResults.count,
        "coverageGaps": coverageGaps.count,
      ],
      forKey: .summary
    )
  }
}

enum ReportRenderer {
  static func table(_ report: CompatReport) -> String {
    let header = [
      "Control class", "Expected", "Actual", "DOM id", "Focus", "Insert", "Select", "Mechanism",
      "Evidence", "Clipboard", "Paste probe", "No false claim", "Gap", "Status",
    ]
    var rows: [[String]] = [header]
    for result in report.results {
      rows.append([
        result.controlClass,
        result.expectedAccess.joined(separator: "|"),
        result.actualAccess,
        result.implementsDOMIdentifier.map { $0 ? "yes" : "no" } ?? "?",
        focusCell(result),
        deliveryCell(result.caretInsertion),
        deliveryCell(result.selectionReplacement),
        mechanismCell(result),
        evidenceCell(result),
        clipboardCell(result.clipboard),
        probeCell(result.standardPasteProbe),
        insertionClaimCell(result.insertionClaimProbe),
        result.coverageGap ? "YES" : "-",
        result.status.uppercased(),
      ])
    }
    let widths = (0..<header.count).map { column in
      rows.map { $0[column].count }.max() ?? 0
    }
    var lines: [String] = []
    for (index, row) in rows.enumerated() {
      let line = row.enumerated()
        .map { $0.element.padding(toLength: widths[$0.offset], withPad: " ", startingAt: 0) }
        .joined(separator: "  ")
      lines.append(line)
      if index == 0 {
        lines.append(widths.map { String(repeating: "-", count: $0) }.joined(separator: "  "))
      }
    }
    return lines.joined(separator: "\n")
  }

  private static func focusCell(_ result: ControlResult) -> String {
    if result.focus.accessibilityConfirmed {
      return result.focus.matchMethod ?? "yes"
    }
    return result.focus.hostConfirmed ? "host-only" : "refused"
  }

  private static func deliveryCell(_ report: DeliveryReport?) -> String {
    guard let report, report.attempted else { return "n/a" }
    guard let match = report.readBackMatch else { return "no-readback" }
    return match ? "ok" : "MISMATCH"
  }

  private static func mechanismCell(_ result: ControlResult) -> String {
    guard let delivery = result.caretInsertion, delivery.attempted else { return "n/a" }
    let observed = delivery.deliveryResult ?? "unknown"
    guard delivery.mechanismMatchesClassification == true else { return "!\(observed)" }
    return observed
  }

  private static func evidenceCell(_ result: ControlResult) -> String {
    guard let delivery = result.caretInsertion, delivery.attempted else { return "n/a" }
    if let paste = delivery.pasteInsertionEvidence {
      return delivery.insertionIsUnverified == true ? "UNVERIFIED(\(paste))" : paste
    }
    return delivery.directInsertionOutcome ?? "none"
  }

  private static func insertionClaimCell(_ report: InsertionClaimProbeReport?) -> String {
    guard let report, report.attempted else { return "-" }
    if report.promisedTextWasRead != true { return "NOT REPRODUCED" }
    if report.wouldClaimInsertion == true { return "CLAIMED" }
    return "held(\(report.insertionEvidence ?? "?"))"
  }

  private static func clipboardCell(_ report: ClipboardReport?) -> String {
    guard let report else { return "n/a" }
    switch report.mode {
    case "notApplicable": return "n/a"
    case "untouchedDirectPath": return report.ok ? "untouched" : "TOUCHED"
    case "afterFailedDelivery": return report.ok ? "kept(fail)" : "LOST(fail)"
    default: return report.ok ? "restored" : "LOST"
    }
  }

  private static func probeCell(_ report: PasteProbeReport?) -> String {
    guard let report, report.attempted else { return "skipped" }
    guard let accepted = report.accepted else { return "unknown" }
    if !accepted { return "refused" }
    return report.pastedVerbatim == false ? "accepted*" : "accepted"
  }
}
