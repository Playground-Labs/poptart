import Foundation

/// The WebKit control surface, expressed as a local HTML string.
///
/// Nothing here is fetched: `loadHTMLString(_:baseURL:)` is given a nil base URL, there is no
/// remote stylesheet, font, script, or image, and the page performs no requests. This keeps the
/// harness inside the repository's absolute no-network rule.
enum WebContent {
  static let inputIdentifier = "webInputText"
  static let textAreaIdentifier = "webTextArea"
  static let contentEditableIdentifier = "webContentEditable"
  static let passwordIdentifier = "webPassword"

  static let identifiers = [
    inputIdentifier, textAreaIdentifier, contentEditableIdentifier, passwordIdentifier,
  ]

  static func html(seed: String, secureSeed: String) -> String {
    """
    <!doctype html>
    <html>
    <head>
    <meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1">
    <style>
      html, body { margin: 0; padding: 8px; font: 13px -apple-system, sans-serif; background: #fff; }
      label { display: block; margin: 6px 0 2px; color: #444; font-size: 11px; }
      input, textarea { width: 96%; font: 13px -apple-system, sans-serif; padding: 3px; }
      #\(contentEditableIdentifier) {
        width: 96%; min-height: 20px; padding: 3px; border: 1px solid #999; background: #fff;
      }
    </style>
    </head>
    <body>
      <label for="\(inputIdentifier)">web input[type=text]</label>
      <input id="\(inputIdentifier)" type="text" value="\(seed)">
      <label for="\(textAreaIdentifier)">web textarea</label>
      <textarea id="\(textAreaIdentifier)" rows="2">\(seed)</textarea>
      <label for="\(contentEditableIdentifier)">web contenteditable div</label>
      <div id="\(contentEditableIdentifier)" contenteditable="true">\(seed)</div>
      <label for="\(passwordIdentifier)">web input[type=password]</label>
      <input id="\(passwordIdentifier)" type="password" value="\(secureSeed)">
      <script>
        var POPTART_IDS = \(jsonArrayLiteral(identifiers));
        var POPTART_SEEDS = {
          "\(inputIdentifier)": \(jsonStringLiteral(seed)),
          "\(textAreaIdentifier)": \(jsonStringLiteral(seed)),
          "\(contentEditableIdentifier)": \(jsonStringLiteral(seed)),
          "\(passwordIdentifier)": \(jsonStringLiteral(secureSeed))
        };
        function poptartIsEditable(el) { return el.hasAttribute("contenteditable"); }
        function poptartValue(el) {
          return poptartIsEditable(el) ? el.textContent : el.value;
        }
        function poptartSetValue(el, text) {
          if (poptartIsEditable(el)) { el.textContent = text; } else { el.value = text; }
        }
        function poptartSnapshot() {
          var out = {};
          for (var i = 0; i < POPTART_IDS.length; i++) {
            var id = POPTART_IDS[i];
            var el = document.getElementById(id);
            var r = el.getBoundingClientRect();
            out[id] = {
              value: poptartValue(el),
              focused: document.activeElement === el,
              rect: { x: r.left, y: r.top, width: r.width, height: r.height }
            };
          }
          return JSON.stringify(out);
        }
        function poptartActive() {
          var el = document.activeElement;
          return el && el.id ? el.id : "";
        }
        function poptartFocus(id) {
          var el = document.getElementById(id);
          if (!el) { return ""; }
          el.focus();
          if (poptartIsEditable(el)) {
            var range = document.createRange();
            range.selectNodeContents(el);
            range.collapse(false);
            var selection = window.getSelection();
            selection.removeAllRanges();
            selection.addRange(range);
          }
          return poptartActive();
        }
        function poptartBlur() {
          if (document.activeElement && document.activeElement.blur) {
            document.activeElement.blur();
          }
          var selection = window.getSelection();
          if (selection) { selection.removeAllRanges(); }
          return poptartActive();
        }
        function poptartSelect(id, location, length) {
          var el = document.getElementById(id);
          if (!el) { return false; }
          el.focus();
          if (!poptartIsEditable(el)) {
            el.setSelectionRange(location, location + length);
            return true;
          }
          var node = el.firstChild;
          if (!node || node.nodeType !== 3) { return false; }
          if (location + length > node.length) { return false; }
          var range = document.createRange();
          range.setStart(node, location);
          range.setEnd(node, location + length);
          var selection = window.getSelection();
          selection.removeAllRanges();
          selection.addRange(range);
          return true;
        }
        function poptartReset() {
          for (var i = 0; i < POPTART_IDS.length; i++) {
            var id = POPTART_IDS[i];
            poptartSetValue(document.getElementById(id), POPTART_SEEDS[id]);
          }
          return poptartBlur();
        }
      </script>
    </body>
    </html>
    """
  }

  private static func jsonArrayLiteral(_ values: [String]) -> String {
    "[" + values.map(jsonStringLiteral).joined(separator: ", ") + "]"
  }

  private static func jsonStringLiteral(_ value: String) -> String {
    let data = try? JSONSerialization.data(withJSONObject: [value])
    guard let data, let text = String(data: data, encoding: .utf8) else { return "\"\"" }
    return String(text.dropFirst().dropLast())
  }
}
