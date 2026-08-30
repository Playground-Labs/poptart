import SystemIntegration

/// Whether a control class is expected to take keyboard focus at all.
enum FocusExpectation: String {
  /// The control must become the Accessibility-focused element.
  case required
  /// The control must refuse focus (a disabled field).
  case refused
  /// Either outcome is legitimate and is recorded rather than judged.
  case optional
}

/// One editable control class, together with what the product definition of "system-wide" says
/// should happen to it: any ordinary editable control that supports Accessibility or standard
/// paste must be usable; secure fields must be refused.
struct ControlSpec {
  let identifier: String
  let controlClass: String
  let expected: [AccessibilityTargetAccess]
  let focus: FocusExpectation
  let isSecure: Bool
  /// Whether the control lives in a web engine. The classifier demotes web-hosted controls to
  /// `pasteOnly` on the strength of `AXDOMIdentifier`, so the harness must check that this flag
  /// and the measured attribute agree for every single control: a native control that exposed
  /// `AXDOMIdentifier` would silently lose its direct path.
  let isWebHosted: Bool
  /// Controls measured to pull the promised pasteboard data and then keep nothing. These are the
  /// counter-examples that make a pasteboard receipt insufficient evidence of an insertion.
  let readsClipboardButAcceptsNothing: Bool

  init(
    identifier: String,
    controlClass: String,
    expected: [AccessibilityTargetAccess],
    focus: FocusExpectation,
    isSecure: Bool,
    isWebHosted: Bool = false,
    readsClipboardButAcceptsNothing: Bool = false
  ) {
    self.identifier = identifier
    self.controlClass = controlClass
    self.expected = expected
    self.focus = focus
    self.isSecure = isSecure
    self.isWebHosted = isWebHosted
    self.readsClipboardButAcceptsNothing = readsClipboardButAcceptsNothing
  }

  var expectsCapture: Bool {
    expected.contains(.direct) || expected.contains(.pasteOnly)
  }

  static let all: [ControlSpec] = [
    .init(
      identifier: "plainTextField", controlClass: "NSTextField (plain)",
      expected: [.direct], focus: .required, isSecure: false),
    .init(
      identifier: "borderedTextField", controlClass: "NSTextField (bordered/rounded)",
      expected: [.direct], focus: .required, isSecure: false),
    .init(
      identifier: "disabledTextField", controlClass: "NSTextField (disabled)",
      expected: [.unsupported], focus: .refused, isSecure: false,
      readsClipboardButAcceptsNothing: true),
    .init(
      identifier: "secureTextField", controlClass: "NSSecureTextField",
      expected: [.secure], focus: .required, isSecure: true),
    .init(
      identifier: "editableTextView", controlClass: "NSTextView in NSScrollView (editable)",
      expected: [.direct], focus: .required, isSecure: false),
    .init(
      identifier: "readOnlyTextView", controlClass: "NSTextView (non-editable)",
      expected: [.unsupported], focus: .optional, isSecure: false,
      readsClipboardButAcceptsNothing: true),
    .init(
      identifier: "searchField", controlClass: "NSSearchField",
      expected: [.direct], focus: .required, isSecure: false),
    .init(
      identifier: "comboBox", controlClass: "NSComboBox",
      expected: [.direct], focus: .required, isSecure: false),
    .init(
      identifier: "tokenField", controlClass: "NSTokenField",
      expected: [.direct], focus: .required, isSecure: false),
    // The three editable web controls advertise AXSelectedTextSettable and then ignore the write,
    // measured. They are expected to be demoted to the clipboard path rather than to pay for it.
    .init(
      identifier: "webInputText", controlClass: "WKWebView input[type=text]",
      expected: [.pasteOnly], focus: .required, isSecure: false, isWebHosted: true),
    .init(
      identifier: "webTextArea", controlClass: "WKWebView textarea",
      expected: [.pasteOnly], focus: .required, isSecure: false, isWebHosted: true),
    .init(
      identifier: "webContentEditable", controlClass: "WKWebView contenteditable div",
      expected: [.pasteOnly], focus: .required, isSecure: false, isWebHosted: true),
    .init(
      identifier: "webPassword", controlClass: "WKWebView input[type=password]",
      expected: [.secure], focus: .required, isSecure: true, isWebHosted: true),
  ]
}
