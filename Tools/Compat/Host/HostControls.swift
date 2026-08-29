import AppKit
import CompatChannel
import WebKit

/// Every editable control class Poptart claims to support, in one window, each with a stable
/// Accessibility identifier so the driver can address it deterministically.
@MainActor
final class HostControls: NSObject {
  static let seed = "ALPHA BRAVO CHARLIE"
  static let secureSeed = "SECRETVALUE"

  /// An AppKit control plus the knowledge needed to read its ground-truth value.
  struct AppKitControl {
    let identifier: String
    let view: NSView
    let seed: String
    let readCounter: AccessibilityReadCounter?
    /// `NSTokenField` turns a committed string into a single token attachment, which leaves its
    /// field editor holding one U+FFFC character. Seeding the field editor directly reproduces the
    /// state a user actually dictates into: an uncommitted, plain-text token being typed.
    let seedsFieldEditor: Bool
  }

  let window: NSWindow
  let webView: WKWebView
  private(set) var appKitControls: [AppKitControl] = []
  private var webLoaded = false
  private var webLoadContinuations: [CheckedContinuation<Void, Never>] = []

  var orderedIdentifiers: [String] {
    appKitControls.map(\.identifier) + WebContent.identifiers
  }

  override init() {
    let contentRect = NSRect(x: 0, y: 0, width: 720, height: 760)
    window = NSWindow(
      contentRect: contentRect,
      styleMask: [.titled, .closable, .miniaturizable],
      backing: .buffered,
      defer: false
    )
    let configuration = WKWebViewConfiguration()
    configuration.suppressesIncrementalRendering = false
    webView = WKWebView(frame: .zero, configuration: configuration)
    super.init()

    window.title = "Poptart Compat Host"
    window.setAccessibilityIdentifier("compatHostWindow")
    let stack = NSStackView()
    stack.orientation = .vertical
    stack.alignment = .leading
    stack.spacing = 6
    stack.edgeInsets = NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
    stack.translatesAutoresizingMaskIntoConstraints = false

    let plain = InstrumentedTextField(string: Self.seed)
    plain.isBordered = false
    plain.isBezeled = false
    plain.drawsBackground = true
    register(plain, identifier: "plainTextField", counter: plain.readCounter, in: stack, label: "NSTextField (plain)")

    let disabled = NSTextField(string: Self.seed)
    disabled.isEnabled = false
    disabled.isEditable = false
    register(disabled, identifier: "disabledTextField", counter: nil, in: stack, label: "NSTextField (disabled)")

    // Deliberately uninstrumented: it is the control group that proves the read counters on
    // `plainTextField` do not perturb what the production path measures.
    let bordered = NSTextField(string: Self.seed)
    bordered.isBezeled = true
    bordered.bezelStyle = .roundedBezel
    register(bordered, identifier: "borderedTextField", counter: nil, in: stack, label: "NSTextField (bordered/rounded)")

    let secure = InstrumentedSecureTextField(string: Self.secureSeed)
    secure.isBezeled = true
    register(secure, identifier: "secureTextField", seed: Self.secureSeed, counter: secure.readCounter, in: stack, label: "NSSecureTextField")

    let editableTextView = Self.makeTextView(identifier: "editableTextView", editable: true)
    register(editableTextView.textView, identifier: "editableTextView", counter: nil, in: stack, label: "NSTextView in NSScrollView (editable)", container: editableTextView.container)

    let readOnlyTextView = Self.makeTextView(identifier: "readOnlyTextView", editable: false)
    register(readOnlyTextView.textView, identifier: "readOnlyTextView", counter: nil, in: stack, label: "NSTextView in NSScrollView (non-editable)", container: readOnlyTextView.container)

    let search = NSSearchField(string: Self.seed)
    register(search, identifier: "searchField", counter: nil, in: stack, label: "NSSearchField")

    let combo = NSComboBox()
    combo.isEditable = true
    combo.addItems(withObjectValues: ["ALPHA", "BRAVO", "CHARLIE"])
    combo.stringValue = Self.seed
    register(combo, identifier: "comboBox", counter: nil, in: stack, label: "NSComboBox")

    let tokens = NSTokenField(string: Self.seed)
    register(tokens, identifier: "tokenField", counter: nil, in: stack, label: "NSTokenField", seedsFieldEditor: true)

    webView.translatesAutoresizingMaskIntoConstraints = false
    webView.setAccessibilityIdentifier("webView")
    webView.navigationDelegate = self
    stack.addArrangedSubview(Self.label("WKWebView (local HTML string, no network)"))
    stack.addArrangedSubview(webView)

    let content = NSView(frame: contentRect)
    content.addSubview(stack)
    window.contentView = content
    NSLayoutConstraint.activate([
      stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
      stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
      stack.topAnchor.constraint(equalTo: content.topAnchor),
      stack.bottomAnchor.constraint(lessThanOrEqualTo: content.bottomAnchor),
      webView.heightAnchor.constraint(equalToConstant: 260),
      webView.widthAnchor.constraint(equalToConstant: 640),
    ])
    for control in appKitControls where control.view is NSTextField {
      control.view.widthAnchor.constraint(equalToConstant: 640).isActive = true
    }
    window.center()
    Self.installMainMenu()
    webView.loadHTMLString(
      WebContent.html(seed: Self.seed, secureSeed: Self.secureSeed),
      baseURL: nil
    )
  }

  // MARK: - Construction helpers

  /// Standard-paste routing depends on the main menu: AppKit dispatches Command key equivalents
  /// through `NSApp.mainMenu` before the responder chain, so an app with no Edit menu silently
  /// ignores Cmd-V. A host without this menu would make every control look like it refused a
  /// standard paste.
  private static func installMainMenu() {
    let main = NSMenu()

    let applicationItem = NSMenuItem()
    let applicationMenu = NSMenu()
    applicationMenu.addItem(
      withTitle: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
    applicationItem.submenu = applicationMenu
    main.addItem(applicationItem)

    let editItem = NSMenuItem()
    let editMenu = NSMenu(title: "Edit")
    editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
    editMenu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
    editMenu.addItem(.separator())
    editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
    editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
    editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
    editMenu.addItem(
      withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
    editItem.submenu = editMenu
    main.addItem(editItem)

    NSApp.mainMenu = main
  }

  private static func label(_ text: String) -> NSTextField {
    let field = NSTextField(labelWithString: text)
    field.font = .systemFont(ofSize: 10)
    field.textColor = .secondaryLabelColor
    field.setAccessibilityElement(false)
    return field
  }

  private static func makeTextView(identifier: String, editable: Bool)
    -> (textView: NSTextView, container: NSScrollView)
  {
    let scrollView = NSScrollView()
    scrollView.translatesAutoresizingMaskIntoConstraints = false
    scrollView.hasVerticalScroller = true
    scrollView.borderType = .bezelBorder
    let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 640, height: 52))
    textView.minSize = NSSize(width: 0, height: 52)
    textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
    textView.isVerticallyResizable = true
    textView.autoresizingMask = [.width]
    textView.isEditable = editable
    textView.isSelectable = true
    textView.isRichText = false
    textView.string = seed
    scrollView.documentView = textView
    NSLayoutConstraint.activate([
      scrollView.heightAnchor.constraint(equalToConstant: 52),
      scrollView.widthAnchor.constraint(equalToConstant: 640),
    ])
    return (textView, scrollView)
  }

  private func register(
    _ view: NSView,
    identifier: String,
    seed: String = HostControls.seed,
    counter: AccessibilityReadCounter?,
    in stack: NSStackView,
    label text: String,
    container: NSView? = nil,
    seedsFieldEditor: Bool = false
  ) {
    view.setAccessibilityIdentifier(identifier)
    stack.addArrangedSubview(Self.label(text))
    stack.addArrangedSubview(container ?? view)
    appKitControls.append(
      .init(
        identifier: identifier,
        view: view,
        seed: seed,
        readCounter: counter,
        seedsFieldEditor: seedsFieldEditor
      ))
  }

  // MARK: - Lookup

  func appKitControl(_ identifier: String) -> AppKitControl? {
    appKitControls.first { $0.identifier == identifier }
  }

  func isWebControl(_ identifier: String) -> Bool {
    WebContent.identifiers.contains(identifier)
  }

  // MARK: - Ground-truth value access

  /// Reads the control's own model, never Accessibility, so a control that silently ignores a
  /// write cannot produce a false pass.
  func value(of control: AppKitControl) -> String? {
    if let textView = control.view as? NSTextView { return textView.string }
    guard let field = control.view as? NSTextField else { return nil }
    if let editor = fieldEditor(for: field) { return editor.string }
    return field.stringValue
  }

  private func fieldEditor(for field: NSTextField) -> NSTextView? {
    guard let editor = window.fieldEditor(false, for: field) as? NSTextView,
      editor.delegate === field
    else { return nil }
    return editor
  }

  func isFocused(_ control: AppKitControl) -> Bool {
    if let textView = control.view as? NSTextView {
      return window.firstResponder === textView
    }
    guard let field = control.view as? NSTextField else { return false }
    if window.firstResponder === field { return true }
    guard let editor = fieldEditor(for: field) else { return false }
    return window.firstResponder === editor
  }

  // MARK: - Operations

  func activate() {
    NSApp.activate(ignoringOtherApps: true)
    window.makeKeyAndOrderFront(nil)
  }

  func blur() async {
    window.makeFirstResponder(nil)
    _ = try? await webView.evaluateJavaScript("poptartBlur()")
  }

  func reset() async {
    for control in appKitControls {
      if let textView = control.view as? NSTextView {
        textView.string = control.seed
        textView.setSelectedRange(NSRange(location: 0, length: 0))
      } else if let field = control.view as? NSTextField {
        field.stringValue = control.seed
      }
    }
    _ = try? await webView.evaluateJavaScript("poptartReset()")
    window.makeFirstResponder(nil)
    // A second pass: dropping the first responder commits the field editor, which can push a
    // stale value back into the control, so the seed is reapplied after focus is released.
    for control in appKitControls {
      if let field = control.view as? NSTextField, field.stringValue != control.seed {
        field.stringValue = control.seed
      }
    }
  }

  func focus(_ identifier: String) async -> Bool {
    if isWebControl(identifier) {
      guard window.makeFirstResponder(webView) else { return false }
      let active = try? await webView.evaluateJavaScript("poptartFocus('\(identifier)')")
      return (active as? String) == identifier
    }
    guard let control = appKitControl(identifier) else { return false }
    guard window.makeFirstResponder(control.view) else { return false }
    if control.seedsFieldEditor, let field = control.view as? NSTextField,
      let editor = fieldEditor(for: field), editor.string != control.seed
    {
      editor.string = control.seed
      editor.setSelectedRange(NSRange(location: 0, length: 0))
    }
    return isFocused(control)
  }

  func setSelection(_ identifier: String, location: Int, length: Int) async -> Bool {
    if isWebControl(identifier) {
      let result = try? await webView.evaluateJavaScript(
        "poptartSelect('\(identifier)', \(location), \(length))")
      return (result as? NSNumber)?.boolValue ?? false
    }
    guard let control = appKitControl(identifier) else { return false }
    let range = NSRange(location: location, length: length)
    if let textView = control.view as? NSTextView {
      guard NSMaxRange(range) <= (textView.string as NSString).length else { return false }
      textView.setSelectedRange(range)
      return textView.selectedRange() == range
    }
    guard let field = control.view as? NSTextField, isFocused(control),
      let editor = fieldEditor(for: field),
      NSMaxRange(range) <= (editor.string as NSString).length
    else { return false }
    editor.setSelectedRange(range)
    return editor.selectedRange() == range
  }

  func focusedControlIdentifier() async -> String? {
    for control in appKitControls where isFocused(control) { return control.identifier }
    guard isWebFirstResponder() else { return nil }
    return await webActiveElement()
  }

  private func isWebFirstResponder() -> Bool {
    guard let responder = window.firstResponder as? NSView else { return false }
    return responder === webView || responder.isDescendant(of: webView)
  }

  func webActiveElement() async -> String? {
    let value = try? await webView.evaluateJavaScript("poptartActive()")
    guard let identifier = value as? String, !identifier.isEmpty else { return nil }
    return identifier
  }

  func snapshot() async -> [CompatControlSnapshot] {
    var snapshots: [CompatControlSnapshot] = []
    for control in appKitControls {
      snapshots.append(
        .init(
          identifier: control.identifier,
          value: value(of: control),
          isFocused: isFocused(control),
          accessibilityValueReads: control.readCounter?.observedReads,
          frame: axFrame(of: control.view)
        ))
    }
    let raw = try? await webView.evaluateJavaScript("poptartSnapshot()")
    let parsed: [String: Any]
    if let text = raw as? String, let data = text.data(using: .utf8),
      let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    {
      parsed = object
    } else {
      parsed = [:]
    }
    for identifier in WebContent.identifiers {
      let entry = parsed[identifier] as? [String: Any]
      let rect = entry?["rect"] as? [String: Any]
      snapshots.append(
        .init(
          identifier: identifier,
          value: entry?["value"] as? String,
          isFocused: (entry?["focused"] as? NSNumber)?.boolValue ?? false,
          accessibilityValueReads: nil,
          frame: rect.flatMap { webFrame($0) }
        ))
    }
    return snapshots
  }

  // MARK: - Geometry

  /// Converts a view rect into Accessibility screen coordinates (top-left origin on the primary
  /// display), which is the space `AXPosition` reports in.
  private func axFrame(of view: NSView) -> CompatRect? {
    guard view.window === window, let primary = NSScreen.screens.first else { return nil }
    let inWindow = view.convert(view.bounds, to: nil)
    let onScreen = window.convertToScreen(inWindow)
    return CompatRect(
      x: onScreen.minX,
      y: primary.frame.maxY - onScreen.maxY,
      width: onScreen.width,
      height: onScreen.height
    )
  }

  private func webFrame(_ rect: [String: Any]) -> CompatRect? {
    guard let x = (rect["x"] as? NSNumber)?.doubleValue,
      let y = (rect["y"] as? NSNumber)?.doubleValue,
      let width = (rect["width"] as? NSNumber)?.doubleValue,
      let height = (rect["height"] as? NSNumber)?.doubleValue,
      webView.window === window
    else { return nil }
    // CSS pixels are laid out from the web view's top-left; AppKit's view space is bottom-left.
    let viewRect = NSRect(
      x: x,
      y: webView.bounds.height - (y + height),
      width: width,
      height: height
    )
    guard let primary = NSScreen.screens.first else { return nil }
    let onScreen = window.convertToScreen(webView.convert(viewRect, to: nil))
    return CompatRect(
      x: onScreen.minX,
      y: primary.frame.maxY - onScreen.maxY,
      width: onScreen.width,
      height: onScreen.height
    )
  }

  // MARK: - Web load gate

  func waitForWebContent() async {
    guard !webLoaded else { return }
    await withCheckedContinuation { continuation in
      webLoadContinuations.append(continuation)
    }
  }
}

extension HostControls: WKNavigationDelegate {
  func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
    webLoaded = true
    let waiting = webLoadContinuations
    webLoadContinuations = []
    for continuation in waiting { continuation.resume() }
  }
}
