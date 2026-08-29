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

  var expectsCapture: Bool {
    expected.contains(.direct) || expected.contains(.pasteOnly)
  }

  static let capturable: [AccessibilityTargetAccess] = [.direct, .pasteOnly]

  static let all: [ControlSpec] = [
    .init(
      identifier: "plainTextField", controlClass: "NSTextField (plain)",
      expected: capturable, focus: .required, isSecure: false),
    .init(
      identifier: "borderedTextField", controlClass: "NSTextField (bordered/rounded)",
      expected: capturable, focus: .required, isSecure: false),
    .init(
      identifier: "disabledTextField", controlClass: "NSTextField (disabled)",
      expected: [.unsupported], focus: .refused, isSecure: false),
    .init(
      identifier: "secureTextField", controlClass: "NSSecureTextField",
      expected: [.secure], focus: .required, isSecure: true),
    .init(
      identifier: "editableTextView", controlClass: "NSTextView in NSScrollView (editable)",
      expected: capturable, focus: .required, isSecure: false),
    .init(
      identifier: "readOnlyTextView", controlClass: "NSTextView (non-editable)",
      expected: [.unsupported], focus: .optional, isSecure: false),
    .init(
      identifier: "searchField", controlClass: "NSSearchField",
      expected: capturable, focus: .required, isSecure: false),
    .init(
      identifier: "comboBox", controlClass: "NSComboBox",
      expected: capturable, focus: .required, isSecure: false),
    .init(
      identifier: "tokenField", controlClass: "NSTokenField",
      expected: capturable, focus: .required, isSecure: false),
    .init(
      identifier: "webInputText", controlClass: "WKWebView input[type=text]",
      expected: capturable, focus: .required, isSecure: false),
    .init(
      identifier: "webTextArea", controlClass: "WKWebView textarea",
      expected: capturable, focus: .required, isSecure: false),
    .init(
      identifier: "webContentEditable", controlClass: "WKWebView contenteditable div",
      expected: capturable, focus: .required, isSecure: false),
    .init(
      identifier: "webPassword", controlClass: "WKWebView input[type=password]",
      expected: [.secure], focus: .required, isSecure: true),
  ]
}
