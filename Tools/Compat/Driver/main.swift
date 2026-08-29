import AppKit
import CompatChannel
import Foundation

/// `PoptartCompatDriver` runs the shipping Accessibility and clipboard adapters against
/// `PoptartCompatHost` and reports the resulting control-class compatibility matrix.
///
/// The driver needs an `NSApplication` run loop rather than an async `main`: `NSPasteboard`
/// delivers promised-data callbacks through the main run loop, and `ClipboardPasteCoordinator`
/// waits for exactly that callback before restoring the clipboard. The activation policy is
/// `.prohibited` so the driver can never steal focus from the host it is measuring.
enum DriverExit {
  static let passed: Int32 = 0
  static let matrixFailed: Int32 = 1
  static let usage: Int32 = 2
  static let permissionMissing: Int32 = 3
  static let harnessError: Int32 = 4
}

func argument(_ name: String) -> String? {
  let arguments = CommandLine.arguments
  guard let index = arguments.firstIndex(of: name), arguments.indices.contains(index + 1) else {
    return nil
  }
  return arguments[index + 1]
}

func writeError(_ message: String) {
  FileHandle.standardError.write(Data((message + "\n").utf8))
}

@MainActor
func runDriver() async -> Int32 {
  guard let outputPath = argument("--output"), let channelPath = argument("--channel") else {
    writeError("usage: PoptartCompatDriver --channel <directory> --output <report.json>")
    return DriverExit.usage
  }

  guard AccessibilityProbe.isTrusted() else {
    AccessibilityProbe.requestTrust()
    writeError(
      """
      Accessibility permission is missing, so the compatibility matrix cannot be measured.

      Grant it once:
        1. Open System Settings > Privacy & Security > Accessibility.
        2. Enable the switch for "PoptartCompatDriver" (add it with + and pick
           .build/PoptartCompatDriver.app if it is not listed).
        3. Re-run Tools/Compat/run.sh.

      No result was produced. This run is NOT a pass.
      """)
    return DriverExit.permissionMissing
  }

  let paths = CompatChannelPaths(root: URL(fileURLWithPath: channelPath, isDirectory: true))
  let client = ChannelClient(paths: paths)
  // The operator's clipboard is borrowed for the restoration checks and handed back untouched.
  let operatorClipboard = PasteboardArchive.capture()
  defer { operatorClipboard.restore() }

  let report: CompatReport
  do {
    report = try await CompatRun(client: client).execute()
  } catch {
    writeError("compat matrix aborted: \(error)")
    return DriverExit.harnessError
  }

  do {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try encoder.encode(report).write(to: URL(fileURLWithPath: outputPath), options: .atomic)
  } catch {
    writeError("could not write the report to \(outputPath): \(error)")
    return DriverExit.harnessError
  }

  print(ReportRenderer.table(report))
  print("")
  print("payload: \"\(report.payload)\"")
  print("calibration ok: \(report.calibration.ok)")
  print("  accessibility read counters: \(report.calibration.detail ?? "no detail")")
  print("  standard paste sentinel:     \(report.calibration.pasteSentinelDetail ?? "no detail")")
  print("  instrument transparency:     \(report.calibration.transparencyDetail ?? "no detail")")
  for result in report.coverageGaps {
    print("")
    print("COVERAGE GAP  \(result.controlClass) [\(result.identifier)]")
    print("  \(result.coverageGapDetail ?? "no detail")")
    if let probe = result.standardPasteProbe {
      print("  evidence: value before=\(probe.valueBefore ?? "nil") after=\(probe.valueAfter ?? "nil")")
    }
  }
  for result in report.failedResults {
    print("")
    print("FAIL  \(result.controlClass) [\(result.identifier)]")
    for failure in result.failures { print("  - \(failure)") }
    if let probe = result.directWriteProbe, probe.attempted {
      print(
        "  direct AXSelectedText write: result=\(probe.accessibilityResultCode.map(String.init) ?? "nil") valueChanged=\(probe.valueChanged.map(String.init) ?? "nil") selection \(probe.selectionBefore ?? "nil") -> \(probe.selectionAfter ?? "nil")"
      )
    }
  }
  if !report.calibration.ok {
    print("")
    print(
      "FAIL  calibration did not hold, so the matrix cannot be trusted: read counters fired=\(report.calibration.instrumentedControlsReadCounted)/\(report.calibration.secureControlReadCounted), standard paste reaches controls=\(report.calibration.standardPasteReachesControls), instrument transparent=\(report.calibration.instrumentationIsTransparent.map(String.init) ?? "unknown")"
    )
  }
  print("")
  print("report written to \(outputPath)")

  guard report.passed else { return DriverExit.matrixFailed }
  print("compat matrix passed")
  return DriverExit.passed
}

let application = NSApplication.shared
application.setActivationPolicy(.prohibited)
Task { @MainActor in
  let code = await runDriver()
  if let statusPath = argument("--status") {
    try? Data("\(code)\n".utf8).write(to: URL(fileURLWithPath: statusPath), options: .atomic)
  }
  fflush(stdout)
  fflush(stderr)
  exit(code)
}
application.run()
