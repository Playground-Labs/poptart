import AppKit
import CompatChannel
import Foundation

/// `PoptartCompatHost` presents one window containing every editable control class the product
/// claims to support and answers a local, file-backed command channel used by
/// `PoptartCompatDriver`. It requires no permissions and performs no network access.
@MainActor
final class CompatHostDelegate: NSObject, NSApplicationDelegate {
  private let paths: CompatChannelPaths
  private var controls: HostControls?
  private var server: HostChannelServer?

  init(paths: CompatChannelPaths) {
    self.paths = paths
  }

  func applicationDidFinishLaunching(_ notification: Notification) {
    let controls = HostControls()
    self.controls = controls
    controls.activate()
    let server = HostChannelServer(paths: paths, controls: controls)
    self.server = server
    server.start()
    Task { @MainActor in
      await controls.waitForWebContent()
      await controls.reset()
      let ready = CompatHostReady(
        processIdentifier: ProcessInfo.processInfo.processIdentifier,
        bundleIdentifier: Bundle.main.bundleIdentifier,
        controls: controls.orderedIdentifiers
      )
      try? CompatChannelIO.write(ready, to: paths.ready)
      FileHandle.standardOutput.write(Data("compat host ready\n".utf8))
    }
  }

  func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    true
  }
}

let arguments = CommandLine.arguments
guard let flag = arguments.firstIndex(of: "--channel"), arguments.indices.contains(flag + 1) else {
  FileHandle.standardError.write(Data("PoptartCompatHost requires --channel <directory>\n".utf8))
  exit(2)
}
let paths = CompatChannelPaths(root: URL(fileURLWithPath: arguments[flag + 1], isDirectory: true))
do {
  try paths.createDirectories()
} catch {
  FileHandle.standardError.write(Data("unusable channel directory: \(error)\n".utf8))
  exit(2)
}

let application = NSApplication.shared
application.setActivationPolicy(.regular)
let delegate = CompatHostDelegate(paths: paths)
application.delegate = delegate
application.run()
