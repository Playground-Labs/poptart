import AppKit
import ApplicationServices
import CompatChannel
import DictationCore
import Foundation
import SystemIntegration

/// Drives the shipping `AccessibilityTextService` and `ClipboardPasteCoordinator` cross-process
/// against `PoptartCompatHost`, one control class at a time.
@MainActor
final class CompatRun {
  static let payload = "Poptart ✓ 42"
  static let probeText = "POPTARTPASTEPROBE"
  private static let selectionLocation = 6
  private static let selectionLength = 5

  private let client: ChannelClient
  /// The shipping delivery publishes what it actually proved about each insertion; the harness
  /// records it rather than re-deriving it, so the report shows the production verdict.
  private let evidence = EvidenceRecorder()
  private let service: AccessibilityTextService
  private let synthesizer = SystemPasteCommandSynthesizer()
  private var hostProcessIdentifier: pid_t = 0
  private var hostBundleIdentifier: String?

  init(client: ChannelClient) {
    self.client = client
    let evidence = self.evidence
    service = AccessibilityTextService(observer: { evidence.record($0) })
  }

  // MARK: - Entry point

  func execute() async throws -> CompatReport {
    let ready = try await client.waitForHost(timeout: .seconds(60))
    hostProcessIdentifier = ready.processIdentifier
    hostBundleIdentifier = ready.bundleIdentifier
    // Guard against host and driver drifting apart: a control class the driver expects but the
    // host no longer presents would otherwise be measured against whatever holds focus instead.
    let missing = ControlSpec.all.map(\.identifier).filter { !ready.controls.contains($0) }
    guard missing.isEmpty else {
      throw CompatRunError.missingControls(missing)
    }
    try await activateHost()

    var calibration = try await calibrateInstrument()
    var results: [ControlResult] = []
    for spec in ControlSpec.all {
      results.append(try await run(spec))
    }
    applyTransparencyCheck(to: &calibration, results: results)
    _ = try? await client.send(.reset)
    return CompatReport(
      generatedAt: ISO8601DateFormatter().string(from: Date()),
      hostBundleIdentifier: hostBundleIdentifier,
      hostProcessIdentifier: hostProcessIdentifier,
      payload: Self.payload,
      calibration: calibration,
      results: results
    )
  }

  // MARK: - Host activation

  /// The production capture path resolves the system-wide focused application, so the host must
  /// genuinely be frontmost before any measurement is taken.
  private func activateHost() async throws {
    _ = try await client.send(.activate)
    let frontmost = await waitUntil(timeout: .seconds(5)) { [self] in
      NSWorkspace.shared.frontmostApplication?.processIdentifier == hostProcessIdentifier
        && AccessibilityProbe.systemFocusedElement()?.processIdentifier == hostProcessIdentifier
    }
    guard frontmost else {
      throw CompatRunError.hostNotFrontmost
    }
  }

  // MARK: - Instrument calibration

  /// Proves the host's Accessibility read counters actually fire, so that "no value read occurred"
  /// on the secure controls is a measurement rather than an assumption.
  private func calibrateInstrument() async throws -> CalibrationReport {
    var report = CalibrationReport()
    _ = try await client.send(.reset)
    var details: [String] = []
    for identifier in ["plainTextField", "secureTextField"] {
      guard
        let element = AccessibilityProbe.findElement(
          identifier: identifier, inApplication: hostProcessIdentifier)
      else {
        details.append("\(identifier): element not found in the host Accessibility tree")
        continue
      }
      let before = try await client.snapshot()[identifier]?.accessibilityValueReads
      _ = AccessibilityProbe.value(of: element)
      let after = try await client.snapshot()[identifier]?.accessibilityValueReads
      let counted = (before.map { before in (after ?? before) > before }) ?? false
      details.append("\(identifier): reads \(before.map(String.init) ?? "nil") -> \(after.map(String.init) ?? "nil")")
      if identifier == "plainTextField" {
        report.instrumentedControlsReadCounted = counted
      } else {
        report.secureControlReadCounted = counted
      }
    }
    report.detail = details.joined(separator: "; ")

    // Sentinel: a plain NSTextField in a window with a standard Edit menu must accept Cmd-V. If it
    // does not, the paste probe is broken and every "refused" verdict below would be worthless.
    if let sentinel = ControlSpec.all.first(where: { $0.identifier == "plainTextField" }) {
      let probe = try await runStandardPasteProbe(sentinel)
      report.standardPasteReachesControls = probe.accepted == true
      report.pasteSentinelDetail =
        "plainTextField accepted=\(probe.accepted.map(String.init) ?? "nil") clipboardWasRead=\(probe.clipboardWasRead.map(String.init) ?? "nil") value=\(probe.valueAfter ?? "nil")"
    }
    return report
  }

  /// The instrumented and uninstrumented `NSTextField`s must behave identically. If they do not,
  /// the read counters are altering the very Accessibility surface the production path reads, and
  /// nothing measured on the instrumented control can be trusted.
  private func applyTransparencyCheck(to calibration: inout CalibrationReport, results: [ControlResult]) {
    guard let instrumented = results.first(where: { $0.identifier == "plainTextField" }),
      let control = results.first(where: { $0.identifier == "borderedTextField" })
    else {
      calibration.transparencyDetail = "the A/B pair of text fields was not measured"
      calibration.instrumentationIsTransparent = false
      return
    }
    let sameClassification = instrumented.actualAccess == control.actualAccess
    let sameMechanism =
      instrumented.caretInsertion?.deliveryResult == control.caretInsertion?.deliveryResult
    let sameCharacterCount =
      instrumented.caretInsertion?.accessibilityCharacterCountBefore
      == control.caretInsertion?.accessibilityCharacterCountBefore
    calibration.instrumentationIsTransparent =
      sameClassification && sameMechanism && sameCharacterCount
    calibration.transparencyDetail =
      "instrumented plainTextField \(instrumented.actualAccess)/\(instrumented.caretInsertion?.deliveryResult ?? "nil")/chars \(instrumented.caretInsertion?.accessibilityCharacterCountBefore.map(String.init) ?? "nil") vs uninstrumented borderedTextField \(control.actualAccess)/\(control.caretInsertion?.deliveryResult ?? "nil")/chars \(control.caretInsertion?.accessibilityCharacterCountBefore.map(String.init) ?? "nil")"
  }

  // MARK: - Per control

  private func run(_ spec: ControlSpec) async throws -> ControlResult {
    var result = ControlResult(
      controlClass: spec.controlClass,
      identifier: spec.identifier,
      expectedAccess: spec.expected.map(\.name)
    )
    try await activateHost()
    _ = try await client.send(.reset)

    let focus = try await establishFocus(spec)
    result.focus = focus.report
    switch spec.focus {
    case .required where !focus.report.accessibilityConfirmed:
      result.failures.append(
        "focus was not confirmed through Accessibility (host reported \(focus.report.hostConfirmed))")
    case .refused where focus.report.hostConfirmed || focus.report.accessibilityConfirmed:
      result.failures.append("a disabled control accepted focus")
    default:
      break
    }

    // Classification. The element under test is the focused element when focus took, which is
    // exactly the element the production capture path reads; otherwise it is the element looked
    // up by identifier, which is the only honest thing left to measure.
    let element: AXUIElement?
    if focus.report.accessibilityConfirmed, let focused = focus.element {
      element = focused
      result.classificationSource = "focusedElement"
    } else if let found = AccessibilityProbe.findElement(
      identifier: spec.identifier, inApplication: hostProcessIdentifier)
    {
      element = found
      result.classificationSource = "elementLookup(control could not be focused)"
    } else {
      element = nil
      result.classificationSource = "unavailable"
      result.failures.append("the control could not be located in the Accessibility tree")
    }

    guard let element else { return result }
    let capabilities = AccessibilityProbe.capabilities(of: element)
    let access = AccessibilityTargetPolicy.access(for: capabilities)
    result.accessibilityRole = capabilities.role
    result.accessibilitySubrole = capabilities.subrole
    result.accessibilityEnabled = capabilities.isEnabled
    result.selectedTextSettable = capabilities.selectedTextSettable
    result.valueSettable = capabilities.valueSettable
    result.implementsDOMIdentifier = capabilities.hasWebDOMIdentifier
    result.domIdentifierValue = AccessibilityProbe.string(
      AccessibilityTargetPolicy.webDOMIdentifierAttribute, of: element)
    result.expectedWebHosted = spec.isWebHosted
    result.actualAccess = access.name
    if !spec.expected.contains(access) {
      result.failures.append(
        "classification mismatch: expected \(spec.expected.map(\.name).joined(separator: "|")), measured \(access.name)"
      )
    }
    // The web demotion is only safe while AXDOMIdentifier means exactly "web-hosted". A native
    // control carrying it would lose its direct path; a web control without it would keep paying
    // for a write measured to do nothing.
    if capabilities.hasWebDOMIdentifier != spec.isWebHosted {
      result.failures.append(
        capabilities.hasWebDOMIdentifier
          ? "a native control implements \(AccessibilityTargetPolicy.webDOMIdentifierAttribute), so demoting web-hosted controls on that signal would demote native controls too"
          : "a web-hosted control does not implement \(AccessibilityTargetPolicy.webDOMIdentifierAttribute), so the classifier cannot recognise it as web-hosted"
      )
    }

    if spec.isSecure {
      try await runSecure(spec, into: &result, access: access)
      return result
    }

    if focus.report.accessibilityConfirmed {
      switch access {
      case .direct, .pasteOnly:
        let caret = try await runDelivery(
          spec, scenario: "caretInsertion", classification: access,
          selection: (Self.selectionLocation, 0))
        result.caretInsertion = caret.delivery
        let replacement = try await runDelivery(
          spec, scenario: "selectionReplacement", classification: access,
          selection: (Self.selectionLocation, Self.selectionLength))
        result.selectionReplacement = replacement.delivery
        result.serviceCaptureOutcome = caret.delivery.captureOutcome
        result.clipboard =
          caret.clipboard.mode == "restoredAfterPaste" ? caret.clipboard : replacement.clipboard
        appendDeliveryFailures(caret.delivery, to: &result)
        appendDeliveryFailures(replacement.delivery, to: &result)
        // Run the probe wherever the element claims AXSelectedText is settable, not only where
        // the classifier believed it: on a demoted control it is the standing evidence that the
        // write really is a no-op and the demotion costs nothing.
        if capabilities.selectedTextSettable {
          let probe = try await runDirectWriteProbe(spec)
          result.directWriteProbe = probe
          if access == .pasteOnly, probe.attempted, probe.valueChanged == true {
            result.failures.append(
              "this control was demoted off the direct path but its AXSelectedText write actually works (value \(quoted(probe.valueBefore)) -> \(quoted(probe.valueAfter))), so the demotion is throwing away a working mechanism"
            )
          }
        }
        if let clipboard = result.clipboard, !clipboard.ok {
          result.failures.append("clipboard check failed in mode \(clipboard.mode)")
        }
      case .unsupported:
        // The shipping capture must refuse this control; record what it actually returned.
        let outcome = await service.captureTarget(for: DictationID())
        result.serviceCaptureOutcome = describe(outcome)
        if case .success = outcome {
          result.failures.append(
            "policy classified the control unsupported but the capture path accepted it")
        }
      case .secure:
        result.failures.append("a non-secure control classified as secure")
      }
    }

    if spec.readsClipboardButAcceptsNothing {
      let claim = try await runInsertionClaimProbe(spec, element: element)
      result.insertionClaimProbe = claim
      appendInsertionClaimFailures(claim, to: &result)
    }

    let probe = try await runStandardPasteProbe(spec)
    result.standardPasteProbe = probe
    if !probe.collateralChanges.isEmpty {
      result.failures.append(
        "the standard paste probe wrote into other controls: \(probe.collateralChanges.joined(separator: ", "))"
      )
    }
    if access == .unsupported, probe.accepted == true {
      result.coverageGap = true
      result.coverageGapDetail =
        "AccessibilityTargetPolicy classified this control unsupported (role=\(capabilities.role ?? "nil"), subrole=\(capabilities.subrole ?? "nil"), enabled=\(capabilities.isEnabled), selectedTextSettable=\(capabilities.selectedTextSettable), valueSettable=\(capabilities.valueSettable)) yet it accepted a plain Cmd-V paste, so Poptart refuses a control the product definition says is in scope."
    }
    _ = try await client.send(.reset)
    return result
  }

  private func appendDeliveryFailures(_ report: DeliveryReport, to result: inout ControlResult) {
    guard report.attempted else {
      result.failures.append("\(report.scenario): delivery was never attempted (\(report.captureOutcome))")
      return
    }
    if report.readBackMatch != true {
      result.failures.append(
        "\(report.scenario): read-back mismatch, expected \(quoted(report.expectedValue)) but the control holds \(quoted(report.hostValue))"
      )
    }
    if report.mechanismMatchesClassification == false {
      result.failures.append(
        "\(report.scenario): the control is classified \(result.actualAccess) but the shipping delivery reported \(report.deliveryResult ?? "nothing"), so the classified mechanism is not the one that ran"
      )
    }
    if report.accessibilityAgreesWithHost == false {
      result.failures.append(
        "\(report.scenario): Accessibility reports \(quoted(report.accessibilityValue)) while the control's own value is \(quoted(report.hostValue))"
      )
    }
    if report.insertionIsUnverified == true {
      result.failures.append(
        "\(report.scenario): the delivery reported \(report.deliveryResult ?? "an insertion") on the pasteboard receipt alone; the read-back said \(report.pasteInsertionEvidence ?? "nothing"), so the claim is unverified"
      )
    }
  }

  private func appendInsertionClaimFailures(
    _ probe: InsertionClaimProbeReport,
    to result: inout ControlResult
  ) {
    if probe.controlAcceptedText == true {
      result.failures.append(
        "the false-insertion probe assumes this control keeps nothing, but its value moved from \(quoted(probe.valueBefore)) to \(quoted(probe.valueAfter)); the matrix's premise for this control is wrong"
      )
      return
    }
    if probe.promisedTextWasRead != true {
      result.failures.append(
        "the false-insertion probe did not reproduce the measured pasteboard read (\(probe.pasteboardOutcome ?? "no outcome")), so it proves nothing about a control that reads the clipboard and accepts nothing"
      )
      return
    }
    // This control is measured to expose a character count and a selection, so the read-back is
    // decisive here: anything other than "the target did not move" means the read-back has stopped
    // being able to catch a false insertion claim on it.
    if probe.insertionEvidence != InsertionEvidence.targetUnchanged.rawValue {
      let measured = probe.insertionEvidence ?? "?"
      let states = "state \(probe.stateBefore ?? "?") -> \(probe.stateAfter ?? "?")"
      result.failures.append(
        measured == InsertionEvidence.unverifiable.rawValue
          ? "the Accessibility read-back can no longer decide this control (\(states)), so it can no longer stop a false insertion claim on a control that reads the promised text and keeps nothing"
          : "the Accessibility read-back reported \(measured) for a control that read the promised text and kept nothing (\(states))"
      )
    }
    // The regression itself: a pasteboard receipt plus a target that kept nothing must never
    // compose into an insertion, whether or not the capture path also refused the control.
    if probe.wouldClaimInsertion == true {
      result.failures.append(
        "the shipping delivery composed \(probe.composedDeliveryResult ?? "an insertion") from a pasteboard receipt on a control that read the promised text and kept nothing (capture refusal held: \(probe.captureRefused.map(String.init) ?? "unknown"))"
      )
    }
    if probe.clipboardRestored != true {
      result.failures.append("the false-insertion probe did not get the clipboard back")
    }
    if !probe.collateralChanges.isEmpty {
      result.failures.append(
        "the false-insertion probe wrote into other controls: \(probe.collateralChanges.joined(separator: ", "))"
      )
    }
  }

  private func quoted(_ value: String?) -> String {
    value.map { "\"\($0)\"" } ?? "nil"
  }

  // MARK: - Focus

  private func establishFocus(_ spec: ControlSpec) async throws -> (
    report: FocusReport, element: AXUIElement?
  ) {
    var report = FocusReport()
    let response = try await client.send(.focus, control: spec.identifier)
    report.hostConfirmed = response.ok && response.focusedControl == spec.identifier
    report.strategy = "hostFirstResponder"
    let hostFrame = (response.controls ?? []).first { $0.identifier == spec.identifier }?.frame

    if let match = await confirmAccessibilityFocus(spec, hostFrame: hostFrame) {
      apply(match, to: &report)
      return (report, match.element)
    }
    // WebKit in particular can leave Accessibility focus behind the DOM, so try the Accessibility
    // route before concluding the control refused focus.
    if let element = AccessibilityProbe.findElement(
      identifier: spec.identifier, inApplication: hostProcessIdentifier),
      AccessibilityProbe.setFocused(element)
    {
      report.strategy = "hostFirstResponder+axFocusedAttribute"
      if let match = await confirmAccessibilityFocus(spec, hostFrame: hostFrame) {
        apply(match, to: &report)
        let refreshed = try await client.send(.snapshot)
        report.hostConfirmed = refreshed.focusedControl == spec.identifier
        return (report, match.element)
      }
    }
    if let focused = AccessibilityProbe.systemFocusedElement(),
      focused.processIdentifier == hostProcessIdentifier
    {
      report.focusedIdentifier = AccessibilityProbe.identifier(of: focused.element)
      report.focusedRole = AccessibilityProbe.string(kAXRoleAttribute, of: focused.element)
      report.focusedSubrole = AccessibilityProbe.string(kAXSubroleAttribute, of: focused.element)
    }
    return (report, nil)
  }

  private struct FocusMatch {
    let element: AXUIElement
    let method: String
    let identifier: String?
    let role: String?
    let subrole: String?
  }

  private func apply(_ match: FocusMatch, to report: inout FocusReport) {
    report.accessibilityConfirmed = true
    report.matchMethod = match.method
    report.focusedIdentifier = match.identifier
    report.focusedRole = match.role
    report.focusedSubrole = match.subrole
  }

  /// Confirms that the Accessibility-focused element really is the control under test.
  ///
  /// AppKit and WebKit both report focus one element away from where the identifier lives: a
  /// combo box focuses its inner text field, and WebKit may or may not surface the DOM id. The
  /// match is therefore attempted by identifier, then by ancestry, then by on-screen geometry,
  /// and the method that succeeded is recorded so a weak match is visible in the report.
  private func confirmAccessibilityFocus(_ spec: ControlSpec, hostFrame: CompatRect?) async
    -> FocusMatch?
  {
    var match: FocusMatch?
    _ = await waitUntil(timeout: .milliseconds(2000)) { [self] in
      guard NSWorkspace.shared.frontmostApplication?.processIdentifier == hostProcessIdentifier,
        let focused = AccessibilityProbe.systemFocusedElement(),
        focused.processIdentifier == hostProcessIdentifier
      else { return false }
      let element = focused.element
      let identifier = AccessibilityProbe.identifier(of: element)
      let role = AccessibilityProbe.string(kAXRoleAttribute, of: element)
      let subrole = AccessibilityProbe.string(kAXSubroleAttribute, of: element)
      if identifier == spec.identifier {
        match = FocusMatch(
          element: element, method: "identifier", identifier: identifier, role: role,
          subrole: subrole)
        return true
      }
      var ancestor = AccessibilityProbe.parent(of: element)
      var depth = 0
      while let current = ancestor, depth < 6 {
        if AccessibilityProbe.identifier(of: current) == spec.identifier {
          match = FocusMatch(
            element: element, method: "ancestorIdentifier(depth \(depth + 1))",
            identifier: identifier, role: role, subrole: subrole)
          return true
        }
        ancestor = AccessibilityProbe.parent(of: current)
        depth += 1
      }
      if let hostFrame, let elementFrame = AccessibilityProbe.frame(of: element),
        elementFrame.overlapFraction(with: hostFrame) >= 0.5,
        hostFrame.overlapFraction(with: elementFrame) >= 0.5
      {
        match = FocusMatch(
          element: element, method: "screenGeometry", identifier: identifier, role: role,
          subrole: subrole)
        return true
      }
      return false
    }
    return match
  }

  // MARK: - Delivery

  private func runDelivery(
    _ spec: ControlSpec,
    scenario: String,
    classification: AccessibilityTargetAccess,
    selection: (location: Int, length: Int)
  ) async throws -> (delivery: DeliveryReport, clipboard: ClipboardReport) {
    var report = DeliveryReport(scenario: scenario)
    var clipboard = ClipboardReport()
    _ = try await client.send(.reset)
    try await activateHost()
    let focus = try await establishFocus(spec)
    guard focus.report.accessibilityConfirmed, let element = focus.element else {
      report.captureOutcome = "skipped: focus was lost before delivery"
      return (report, clipboard)
    }
    let selectionApplied = try await client.send(
      .setSelection, control: spec.identifier,
      location: selection.location, length: selection.length)
    guard selectionApplied.ok else {
      report.captureOutcome = "skipped: the control refused the selection"
      report.notes.append(selectionApplied.error ?? "no error reported")
      return (report, clipboard)
    }
    guard
      let seed = (selectionApplied.controls ?? []).first(where: { $0.identifier == spec.identifier })?
        .value
    else {
      report.captureOutcome = "skipped: the host could not read the control's value"
      return (report, clipboard)
    }
    report.seedValue = seed
    let seedText = seed as NSString
    let range = NSRange(location: selection.location, length: selection.length)
    guard NSMaxRange(range) <= seedText.length else {
      report.captureOutcome = "skipped: the seed value is shorter than the test selection"
      return (report, clipboard)
    }
    report.expectedValue = seedText.replacingCharacters(in: range, with: Self.payload)

    // Confirm through Accessibility that the selection propagated, because the production capture
    // records the selection it reads and revalidates against it before writing.
    let selectionVisible = await waitUntil(timeout: .milliseconds(1000)) {
      AccessibilityProbe.selectedRange(of: element)
        == TextSelection(location: selection.location, length: selection.length)
    }
    if !selectionVisible {
      report.notes.append(
        "Accessibility did not report the requested selection; measured \(String(describing: AccessibilityProbe.selectedRange(of: element)))"
      )
    }

    report.accessibilityCharacterCountBefore = AccessibilityProbe.integer(
      kAXNumberOfCharactersAttribute, of: element)
    report.accessibilitySelectionBefore = describe(AccessibilityProbe.selectedRange(of: element))

    let changeCountBefore = ClipboardSeed.write()
    clipboard.changeCountBefore = changeCountBefore

    let dictation = DictationID()
    let capture = await service.captureTarget(for: dictation)
    report.captureOutcome = describe(capture)
    guard case .success(.editable(let target, _)) = capture else {
      clipboard.mode = "notApplicable"
      clipboard.ok = ClipboardSeed.stringSurvived
      return (report, clipboard)
    }
    report.attempted = true
    let deadline = MonotonicInstant(
      nanoseconds: Int64(clamping: DispatchTime.now().uptimeNanoseconds) + 5_000_000_000)
    evidence.reset()
    let delivery = await service.deliver(
      .init(id: dictation, target: target, text: Self.payload, deadline: deadline))
    report.deliveryResult = describe(delivery)
    if let published = evidence.take() {
      report.directInsertionOutcome = published.directInsertion?.rawValue
      report.pasteInsertionEvidence = published.pasteInsertion?.rawValue
      report.insertionIsUnverified = published.insertionIsUnverified
      if published.result != delivery {
        report.notes.append(
          "the delivery published evidence for a different result than it returned")
      }
    } else {
      report.notes.append("the delivery published no evidence")
    }
    // The classification is the one measured before the write, not one re-read afterwards, so a
    // control that changes shape mid-delivery cannot make the mechanism check pass by accident.
    let expectedMechanism: DeliveryMethod? =
      switch classification {
      case .direct: .accessibility
      case .pasteOnly: .clipboardPaste
      default: nil
      }
    if case .inserted(let method) = delivery {
      report.mechanismMatchesClassification = method == expectedMechanism
    } else {
      report.mechanismMatchesClassification = false
    }

    let expected = report.expectedValue
    var hostValue: String?
    _ = await waitUntil(timeout: .milliseconds(2000)) { [self] in
      hostValue = try? await client.value(of: spec.identifier)
      return hostValue == expected
    }
    report.hostValue = hostValue
    report.readBackMatch = hostValue == expected

    // Accessibility read-back is what production trusts, so it is compared against the control's
    // own value; a disagreement means a control could silently ignore a write and still look fine.
    var accessibilityValue: String?
    _ = await waitUntil(timeout: .milliseconds(1000)) {
      accessibilityValue = AccessibilityProbe.value(of: element)
      return accessibilityValue == hostValue
    }
    report.accessibilityValue = accessibilityValue
    report.accessibilityAgreesWithHost = accessibilityValue == nil ? nil : accessibilityValue == hostValue
    report.accessibilityCharacterCountAfter = AccessibilityProbe.integer(
      kAXNumberOfCharactersAttribute, of: element)
    report.accessibilitySelectionAfter = describe(AccessibilityProbe.selectedRange(of: element))
    if case .failed = delivery {
      report.notes.append(
        "the shipping delivery reported failure; expected character count after a direct write was \(seedText.length - selection.length + (Self.payload as NSString).length)"
      )
    }

    clipboard.changeCountAfter = NSPasteboard.general.changeCount
    switch delivery {
    case .inserted(.clipboardPaste):
      clipboard.mode = "restoredAfterPaste"
      clipboard.stringRestored = ClipboardSeed.stringSurvived
      clipboard.markerRestored = ClipboardSeed.markerSurvived
      clipboard.ok = clipboard.stringRestored == true && clipboard.markerRestored == true
    case .inserted(.accessibility):
      clipboard.mode = "untouchedDirectPath"
      clipboard.stringRestored = ClipboardSeed.stringSurvived
      clipboard.markerRestored = ClipboardSeed.markerSurvived
      clipboard.ok =
        clipboard.changeCountAfter == changeCountBefore && clipboard.stringRestored == true
        && clipboard.markerRestored == true
    default:
      clipboard.mode = "afterFailedDelivery"
      clipboard.stringRestored = ClipboardSeed.stringSurvived
      clipboard.markerRestored = ClipboardSeed.markerSurvived
      clipboard.ok = clipboard.stringRestored == true && clipboard.markerRestored == true
    }
    return (report, clipboard)
  }

  // MARK: - Secure controls

  private func runSecure(
    _ spec: ControlSpec,
    into result: inout ControlResult,
    access: AccessibilityTargetAccess
  ) async throws {
    var report = SecureReport()
    let before = try await client.snapshot()
    let seedValue = before[spec.identifier]?.value
    let readsBefore = before[spec.identifier]?.accessibilityValueReads
    report.instrumented = readsBefore != nil
    if readsBefore == nil {
      report.note =
        "WebKit controls are not read-instrumented; the guarantee here is that the capture returns the secure case, which structurally carries no text, and that nothing was written."
    }
    let pasteboardChangeCountBefore = NSPasteboard.general.changeCount

    let dictation = DictationID()
    let capture = await service.captureTarget(for: dictation)
    result.serviceCaptureOutcome = describe(capture)
    guard case .success(.secure(let application, let elementIdentifier)) = capture else {
      report.captureRefused = false
      result.secure = report
      result.failures.append("the capture path did not refuse a secure control: \(describe(capture))")
      return
    }
    report.captureRefused = true

    // A secure capture must not be usable for delivery. Driving the real delivery with the
    // identifiers the secure capture handed back proves the text has nowhere to land.
    let deadline = MonotonicInstant(
      nanoseconds: Int64(clamping: DispatchTime.now().uptimeNanoseconds) + 2_000_000_000)
    let delivery = await service.deliver(
      .init(
        id: dictation,
        target: .init(
          applicationIdentifier: application,
          elementIdentifier: elementIdentifier,
          selection: nil),
        text: Self.payload,
        deadline: deadline))
    if case .failed = delivery {
      report.deliveryRefused = true
    }

    let after = try await client.snapshot()
    let readsAfter = after[spec.identifier]?.accessibilityValueReads
    if let readsBefore, let readsAfter {
      report.accessibilityValueReadsDuringCapture = readsAfter - readsBefore
    }
    report.valueUnchanged = after[spec.identifier]?.value == seedValue
    report.pasteboardUntouched = NSPasteboard.general.changeCount == pasteboardChangeCountBefore

    if !report.deliveryRefused {
      result.failures.append("a secure capture still produced a delivery: \(describe(delivery))")
    }
    if !report.valueUnchanged {
      result.failures.append("the secure control's value changed during the secure test")
    }
    if !report.pasteboardUntouched {
      result.failures.append("the secure path wrote to the pasteboard")
    }
    if let reads = report.accessibilityValueReadsDuringCapture, reads != 0 {
      result.failures.append("the capture path performed \(reads) Accessibility value reads on a secure control")
    }
    result.secure = report
    // No paste probe is run against a secure control: the harness must never write text into one.
    result.standardPasteProbe = PasteProbeReport(
      attempted: false,
      skippedReason: "the harness never writes text into a secure control")
  }

  // MARK: - Direct write probe

  /// Performs the same `AXSelectedText` write the shipping delivery performs, in isolation, so a
  /// `direct` classification that never actually writes is evidenced rather than inferred.
  private func runDirectWriteProbe(_ spec: ControlSpec) async throws -> DirectWriteProbeReport {
    var report = DirectWriteProbeReport()
    _ = try await client.send(.reset)
    try await activateHost()
    let focus = try await establishFocus(spec)
    guard focus.report.accessibilityConfirmed, let element = focus.element else { return report }
    let selection = try await client.send(
      .setSelection, control: spec.identifier,
      location: Self.selectionLocation, length: Self.selectionLength)
    guard selection.ok else { return report }
    report.valueBefore = (selection.controls ?? []).first { $0.identifier == spec.identifier }?.value
    report.selectionBefore = describe(AccessibilityProbe.selectedRange(of: element))
    report.attempted = true
    let code = AXUIElementSetAttributeValue(
      element, kAXSelectedTextAttribute as CFString, "DIRECTWRITEPROBE" as CFTypeRef)
    report.accessibilityResultCode = code.rawValue
    var value = report.valueBefore
    _ = await waitUntil(timeout: .milliseconds(500)) { [self] in
      value = try? await client.value(of: spec.identifier)
      return value != report.valueBefore
    }
    report.valueAfter = value
    report.valueChanged = value != report.valueBefore
    report.selectionAfter = describe(AccessibilityProbe.selectedRange(of: element))
    _ = try await client.send(.reset)
    return report
  }

  // MARK: - False insertion claim probe

  /// Reproduces, end to end and with shipping code only, the case that makes a pasteboard receipt
  /// insufficient evidence: a control that pulls the promised text off the pasteboard and keeps
  /// nothing. Two independent gates must stop an insertion claim - the capture refusing the
  /// control, and the post-paste Accessibility read-back seeing an unmoved target - and the probe
  /// records which of them held.
  private func runInsertionClaimProbe(_ spec: ControlSpec, element: AXUIElement) async throws
    -> InsertionClaimProbeReport
  {
    var report = InsertionClaimProbeReport()
    _ = try await client.send(.reset)
    try await activateHost()
    let focus = try await client.send(.focus, control: spec.identifier)
    report.focusEstablished = focus.ok && focus.focusedControl == spec.identifier
    if !report.focusEstablished {
      // A disabled control cannot take focus, which is the point: the Cmd-V must go nowhere rather
      // than into whichever control happens to hold focus.
      _ = try await client.send(.blur)
    }

    let dictation = DictationID()
    let capture = await service.captureTarget(for: dictation)
    report.captureOutcome = describe(capture)
    if case .success(.editable) = capture {
      report.captureRefused = false
    } else {
      report.captureRefused = true
    }
    await service.cancelDelivery(for: dictation)

    let before = try await client.snapshot()
    report.valueBefore = before[spec.identifier]?.value
    let stateBefore = AccessibilityProbe.textState(of: element)
    report.stateBefore = describe(stateBefore)

    report.attempted = true
    // A synthesised Cmd-V can be dropped while an application is still settling, and an unread
    // promise measures nothing. Retry a bounded number of times so that "the promise was never
    // read" is a conclusion about the control rather than about the harness's timing.
    var outcome = ClipboardPasteOutcome.failed(.pasteTimedOut)
    var attempts: [String] = []
    for attempt in 1...3 {
      ClipboardSeed.write()
      let deadline = MonotonicInstant(
        nanoseconds: Int64(clamping: DispatchTime.now().uptimeNanoseconds) + 3_000_000_000)
      outcome = await ClipboardPasteCoordinator().pastePreservingClipboard(
        text: Self.probeText, deadline: deadline)
      attempts.append("attempt \(attempt): \(describe(outcome))")
      if outcome == .promisedTextWasRead { break }
      try await activateHost()
    }
    report.pasteAttempts = attempts
    report.pasteboardOutcome = describe(outcome)
    report.promisedTextWasRead = outcome == .promisedTextWasRead

    // Give the control the same settling time every other probe gets before concluding it kept
    // nothing, so "unchanged" is a measurement rather than a race the harness won.
    var stateAfter = stateBefore
    _ = await waitUntil(timeout: .milliseconds(1000)) {
      stateAfter = AccessibilityProbe.textState(of: element)
      return stateAfter != stateBefore
    }
    report.stateAfter = describe(stateAfter)

    let insertionEvidence = PasteInsertionConfirmation.evidence(
      before: stateBefore, after: stateAfter, insertedUTF16Count: Self.probeText.utf16.count)
    report.insertionEvidence = insertionEvidence.rawValue
    let composed = PasteInsertionConfirmation.deliveryResult(
      outcome: outcome, evidence: insertionEvidence)
    report.composedDeliveryResult = describe(composed)
    if case .inserted = composed {
      report.wouldClaimInsertion = true
    } else {
      report.wouldClaimInsertion = false
    }

    let after = try await client.snapshot()
    report.valueAfter = after[spec.identifier]?.value
    report.controlAcceptedText = report.valueAfter != report.valueBefore
    report.collateralChanges = before.keys
      .filter { $0 != spec.identifier && before[$0]?.value != after[$0]?.value }
      .sorted()
    report.clipboardRestored = ClipboardSeed.stringSurvived && ClipboardSeed.markerSurvived
    _ = try await client.send(.reset)
    return report
  }

  // MARK: - Coverage probe

  /// Asks the only question that matters for the product definition: would this control have
  /// accepted an ordinary Cmd-V?
  private func runStandardPasteProbe(_ spec: ControlSpec) async throws -> PasteProbeReport {
    var report = PasteProbeReport()
    _ = try await client.send(.reset)
    try await activateHost()
    let focus = try await client.send(.focus, control: spec.identifier)
    report.focusEstablished = focus.ok && focus.focusedControl == spec.identifier
    if !report.focusEstablished {
      // Never let a stray Cmd-V land in whichever control happens to hold focus.
      _ = try await client.send(.blur)
    }
    let before = try await client.snapshot()
    report.valueBefore = before[spec.identifier]?.value

    let archive = PasteboardArchive.capture()
    let writer = ProbePasteboardWriter(text: Self.probeText)
    guard writer.write() else {
      archive.restore()
      report.attempted = false
      return report
    }
    report.attempted = true
    guard await synthesizer.paste() else {
      archive.restore()
      report.accepted = false
      return report
    }
    var after = before
    _ = await waitUntil(timeout: .milliseconds(1500)) { [self] in
      after = (try? await client.snapshot()) ?? after
      return after[spec.identifier]?.value != report.valueBefore
    }
    report.clipboardWasRead = writer.wasRead
    report.clipboardRestored = archive.restore()
    report.valueAfter = after[spec.identifier]?.value
    report.accepted = report.valueAfter != report.valueBefore
    report.pastedVerbatim = report.valueAfter?.contains(Self.probeText) == true
    report.collateralChanges = before.keys
      .filter { $0 != spec.identifier && before[$0]?.value != after[$0]?.value }
      .sorted()
    _ = try await client.send(.reset)
    return report
  }

  // MARK: - Descriptions

  private func describe(_ capture: Result<DictationTargetCapture, TargetCaptureFailure>) -> String {
    switch capture {
    case .success(.editable): "editable"
    case .success(.secure): "secure"
    case .failure(let failure): "failure(\(failure.rawValue))"
    }
  }

  private func describe(_ selection: TextSelection?) -> String {
    selection.map { "{\($0.location), \($0.length)}" } ?? "nil"
  }

  private func describe(_ state: TargetTextState) -> String {
    "chars \(state.characterCount.map(String.init) ?? "nil") sel \(describe(state.selection))"
  }

  private func describe(_ outcome: ClipboardPasteOutcome) -> String {
    switch outcome {
    case .promisedTextWasRead: "promisedTextWasRead"
    case .failed(let failure): "failed(\(failure.rawValue))"
    }
  }

  private func describe(_ result: DeliveryResult) -> String {
    switch result {
    case .inserted(let method): "inserted(\(method.rawValue))"
    case .copiedToClipboard: "copiedToClipboard"
    case .failed(let failure): "failed(\(failure.rawValue))"
    }
  }

  // MARK: - Waiting

  private func waitUntil(
    timeout: Duration,
    poll: Duration = .milliseconds(20),
    _ condition: () async -> Bool
  ) async -> Bool {
    let deadline = ContinuousClock.now + timeout
    while true {
      if await condition() { return true }
      if ContinuousClock.now >= deadline { return false }
      try? await Task.sleep(for: poll)
    }
  }
}

/// Captures what the shipping delivery published about its most recent attempt. The observer can
/// be invoked from whichever context the delivery runs on, so the slot is lock protected.
final class EvidenceRecorder: @unchecked Sendable {
  private let lock = NSLock()
  private var latest: DeliveryEvidence?

  func record(_ evidence: DeliveryEvidence) {
    lock.withLock { latest = evidence }
  }

  func reset() {
    lock.withLock { latest = nil }
  }

  func take() -> DeliveryEvidence? {
    lock.withLock {
      defer { latest = nil }
      return latest
    }
  }
}

enum CompatRunError: Error, CustomStringConvertible {
  case hostNotFrontmost
  case missingControls([String])

  var description: String {
    switch self {
    case .hostNotFrontmost:
      "the compat host never became the frontmost application, so no Accessibility measurement would be meaningful"
    case .missingControls(let identifiers):
      "the compat host does not present these control classes: \(identifiers.joined(separator: ", "))"
    }
  }
}
