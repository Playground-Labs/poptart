import AppKit
import DictationCore
import Foundation

public actor IndicatorPresenter: IndicatorBoundary {
  public init() {}

  public func present(_ snapshot: IndicatorSnapshot) async {
    let visual = IndicatorVisual(snapshot.state)
    await IndicatorUI.shared.present(visual)
  }
}

@MainActor
private final class IndicatorUI {
  static let shared = IndicatorUI()

  private let panel: IndicatorPanel
  private let indicatorView: IndicatorView

  private init() {
    indicatorView = IndicatorView(frame: NSRect(x: 0, y: 0, width: 68, height: 28))
    panel = IndicatorPanel(
      contentRect: indicatorView.bounds,
      styleMask: [.borderless, .nonactivatingPanel],
      backing: .buffered,
      defer: false
    )
    panel.contentView = indicatorView
    panel.backgroundColor = .clear
    panel.isOpaque = false
    panel.hasShadow = true
    panel.level = .floating
    panel.hidesOnDeactivate = false
    panel.isFloatingPanel = true
    panel.becomesKeyOnlyIfNeeded = true
    panel.ignoresMouseEvents = true
    panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
    positionPanel()
  }

  func present(_ visual: IndicatorVisual) {
    indicatorView.visual = visual
    positionPanel()
    panel.orderFrontRegardless()
  }

  private func positionPanel() {
    guard let screen = NSScreen.main else { return }
    let visible = screen.visibleFrame
    let origin = NSPoint(
      x: visible.midX - panel.frame.width / 2,
      y: visible.maxY - panel.frame.height - 10
    )
    panel.setFrameOrigin(origin)
  }
}

@MainActor
private final class IndicatorPanel: NSPanel {
  override var canBecomeKey: Bool { false }
  override var canBecomeMain: Bool { false }
}

@MainActor
private final class IndicatorView: NSView {
  var visual = IndicatorVisual(.ready) {
    didSet {
      setAccessibilityLabel(visual.accessibilityDescription)
      needsDisplay = true
    }
  }

  override var isFlipped: Bool { true }

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    setAccessibilityElement(true)
    setAccessibilityRole(.init(rawValue: "AXGroup"))
    setAccessibilityLabel(visual.accessibilityDescription)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) is unavailable")
  }

  override func draw(_ dirtyRect: NSRect) {
    super.draw(dirtyRect)
    let background = NSBezierPath(roundedRect: bounds, xRadius: 14, yRadius: 14)
    NSColor.windowBackgroundColor.withAlphaComponent(0.92).setFill()
    background.fill()

    color(for: visual.tone).setFill()
    let centerY = bounds.midY
    if let activity = visual.audioActivity {
      let level = min(1, max(0, activity))
      for index in 0..<3 {
        let multiplier = [0.55, 1.0, 0.72][index]
        let height = 5 + (12 * level * multiplier)
        let rect = NSRect(
          x: 25 + CGFloat(index * 7), y: centerY - height / 2, width: 4, height: height)
        NSBezierPath(roundedRect: rect, xRadius: 2, yRadius: 2).fill()
      }
    } else {
      let mark = NSRect(x: bounds.midX - 5, y: centerY - 5, width: 10, height: 10)
      // Colour alone would not carry this: the one completion that still needs the person to act
      // is also the one they may be reading at a glance, or not distinguishing by hue at all.
      if visual.tone == .copied {
        NSBezierPath(roundedRect: mark, xRadius: 2, yRadius: 2).fill()
      } else {
        NSBezierPath(ovalIn: mark).fill()
      }
    }
  }

  private func color(for tone: IndicatorTone) -> NSColor {
    switch tone {
    case .neutral: .secondaryLabelColor
    case .active: .systemBlue
    case .warning: .systemOrange
    case .success: .systemGreen
    case .fallback: .systemYellow
    case .copied: .systemPurple
    case .failure: .systemRed
    }
  }
}
