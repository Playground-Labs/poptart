import AppKit
import DictationCore
import Foundation
import QuartzCore

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

  /// The panel is the silhouette, so its size is part of the vocabulary, not a layout detail.
  private static func size(for shape: IndicatorShape) -> NSSize {
    switch shape {
    case .collapsed: NSSize(width: 64, height: 10)
    case .waveform: NSSize(width: 163, height: 44)
    case .spinner: NSSize(width: 72, height: 44)
    }
  }

  private static let screenInset: CGFloat = 10
  private static let toastGap: CGFloat = 8
  private static let morphDuration: TimeInterval = 0.3

  private let panel: IndicatorPanel
  private let indicatorView: IndicatorView
  private let toast: ToastUI
  private var shape: IndicatorShape = .collapsed

  private init() {
    indicatorView = IndicatorView(
      frame: NSRect(origin: .zero, size: IndicatorUI.size(for: .collapsed)))
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
    toast = ToastUI()
    layOut(shape: .collapsed, animated: false)
  }

  func present(_ visual: IndicatorVisual) {
    indicatorView.visual = visual
    if visual.shape != shape {
      layOut(shape: visual.shape, animated: panel.isVisible)
    }
    panel.orderFrontRegardless()
    if let message = visual.toast {
      toast.show(message, above: targetFrame(for: shape))
    }
  }

  private func targetFrame(for shape: IndicatorShape) -> NSRect {
    guard let screen = NSScreen.main else { return panel.frame }
    let visible = screen.visibleFrame
    let size = IndicatorUI.size(for: shape)
    // `visibleFrame` already excludes the Dock, so the bottom edge is the Dock's top edge.
    return NSRect(
      x: visible.midX - size.width / 2,
      y: visible.minY + IndicatorUI.screenInset,
      width: size.width,
      height: size.height
    )
  }

  private func layOut(shape: IndicatorShape, animated: Bool) {
    self.shape = shape
    let frame = targetFrame(for: shape)
    let toastOrigin = NSPoint(x: frame.midX, y: frame.maxY + IndicatorUI.toastGap)
    guard animated else {
      panel.setFrame(frame, display: true)
      toast.anchor(at: toastOrigin, animated: false)
      return
    }
    NSAnimationContext.runAnimationGroup { context in
      context.duration = IndicatorUI.morphDuration
      context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
      panel.animator().setFrame(frame, display: true)
    }
    toast.anchor(at: toastOrigin, animated: true)
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
      applyShape()
      needsDisplay = true
    }
  }

  /// The bars are driven by one amplitude scalar, not by an FFT. `audioActivity` has always been a
  /// single 0...1 level; the per-bar variation below is decoration chosen to read as speech, and
  /// no bar corresponds to a frequency band. Do not "fix" this by reading it as spectrum data.
  private static let barWeights: [Double] = [
    0.32, 0.55, 0.41, 0.78, 0.62, 0.93, 0.70, 1.00, 0.84, 0.58, 0.88,
    0.47, 0.72, 0.95, 0.66, 0.38, 0.81, 0.52, 0.60, 0.35, 0.28,
  ]
  /// With no level yet, the waveform rests rather than collapsing: an empty pill would read as a
  /// dead microphone.
  private static let restingLevel = 0.12

  private let spinnerLayer = CAShapeLayer()
  private var waveformTimer: Timer?
  private var phase: Double = 0

  override var isFlipped: Bool { true }

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    wantsLayer = true
    setAccessibilityElement(true)
    setAccessibilityRole(.init(rawValue: "AXGroup"))
    setAccessibilityLabel(visual.accessibilityDescription)
    spinnerLayer.fillColor = nil
    spinnerLayer.lineWidth = 2.5
    spinnerLayer.lineCap = .round
    spinnerLayer.isHidden = true
    layer?.addSublayer(spinnerLayer)
    applyShape()
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) is unavailable")
  }

  override func layout() {
    super.layout()
    let side = min(20, max(0, bounds.height - 16))
    CATransaction.begin()
    // The panel morph already animates the size; an implicit layer animation on top of it would
    // trail the panel edge.
    CATransaction.setDisableActions(true)
    spinnerLayer.frame = NSRect(
      x: bounds.midX - side / 2, y: bounds.midY - side / 2, width: side, height: side)
    spinnerLayer.path = IndicatorView.arcPath(side: side)
    spinnerLayer.strokeColor = NSColor.labelColor.cgColor
    CATransaction.commit()
  }

  override func viewDidChangeEffectiveAppearance() {
    super.viewDidChangeEffectiveAppearance()
    spinnerLayer.strokeColor = NSColor.labelColor.cgColor
    needsDisplay = true
  }

  override func draw(_ dirtyRect: NSRect) {
    super.draw(dirtyRect)
    drawSurface()
    switch visual.shape {
    case .collapsed, .spinner:
      break
    case .waveform(let level):
      drawWaveform(level: level)
    }
  }

  private func drawSurface() {
    let radius = min(cornerRadius(for: visual.shape), bounds.height / 2)
    let inset = bounds.insetBy(dx: 0.5, dy: 0.5)
    let surface = NSBezierPath(roundedRect: inset, xRadius: radius, yRadius: radius)
    NSColor.windowBackgroundColor.withAlphaComponent(0.92).setFill()
    surface.fill()
    NSColor.separatorColor.setStroke()
    surface.lineWidth = 1
    surface.stroke()
  }

  private func drawWaveform(level: Double?) {
    let level = level.map { min(1, max(0, $0)) } ?? IndicatorView.restingLevel
    let inset: CGFloat = 10
    let available = max(0, bounds.width - inset * 2)
    let count = IndicatorView.barWeights.count
    let pitch = available / CGFloat(count)
    let barWidth = max(1, pitch * 0.43)
    let resting: CGFloat = 3
    let tallest = max(resting, bounds.height - 14)
    NSColor.labelColor.setFill()
    for index in 0..<count {
      let ripple = 0.65 + 0.35 * sin(phase * 2.4 + Double(index) * 0.55)
      let amplitude = level * IndicatorView.barWeights[index] * ripple
      let height = resting + (tallest - resting) * CGFloat(amplitude)
      let rect = NSRect(
        x: inset + pitch * CGFloat(index) + (pitch - barWidth) / 2,
        y: bounds.midY - height / 2,
        width: barWidth,
        height: height
      )
      NSBezierPath(roundedRect: rect, xRadius: barWidth / 2, yRadius: barWidth / 2).fill()
    }
  }

  private func cornerRadius(for shape: IndicatorShape) -> CGFloat {
    switch shape {
    case .collapsed: 5
    case .waveform, .spinner: 22
    }
  }

  private func applyShape() {
    switch visual.shape {
    case .waveform:
      stopSpinner()
      startWaveform()
    case .spinner:
      stopWaveform()
      startSpinner()
    case .collapsed:
      stopWaveform()
      stopSpinner()
    }
  }

  private func startWaveform() {
    guard waveformTimer == nil else { return }
    // The phase only moves while a waveform is on screen; nothing animates in the resting sliver.
    waveformTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) {
      [weak self] _ in
      MainActor.assumeIsolated {
        guard let self else { return }
        self.phase += 1.0 / 30.0
        self.needsDisplay = true
      }
    }
  }

  private func stopWaveform() {
    waveformTimer?.invalidate()
    waveformTimer = nil
  }

  private func startSpinner() {
    spinnerLayer.isHidden = false
    guard spinnerLayer.animation(forKey: "spin") == nil else { return }
    let spin = CABasicAnimation(keyPath: "transform.rotation.z")
    spin.fromValue = 0
    spin.toValue = -2 * Double.pi
    spin.duration = 0.9
    spin.repeatCount = .infinity
    spinnerLayer.add(spin, forKey: "spin")
  }

  private func stopSpinner() {
    spinnerLayer.removeAnimation(forKey: "spin")
    spinnerLayer.isHidden = true
  }

  private static func arcPath(side: CGFloat) -> CGPath {
    let path = CGMutablePath()
    let radius = max(0, side / 2 - 1.25)
    path.addArc(
      center: CGPoint(x: side / 2, y: side / 2),
      radius: radius,
      startAngle: 0,
      endAngle: .pi * 1.5,
      clockwise: false
    )
    return path
  }
}

/// The toast is the only surface that speaks in words, and it only ever speaks the fixed strings
/// from `IndicatorVisual.toast`. Transcript text must never reach it.
@MainActor
private final class ToastUI {
  private static let lifetime: TimeInterval = 2.4
  private static let fadeDuration: TimeInterval = 0.2

  private let panel: ToastPanel
  private let view: ToastView
  private var dismissal: Timer?
  private var message: String?
  private var anchor: NSPoint = .zero

  init() {
    view = ToastView()
    panel = ToastPanel(
      contentRect: NSRect(origin: .zero, size: view.fittingSize),
      styleMask: [.borderless, .nonactivatingPanel],
      backing: .buffered,
      defer: false
    )
    panel.contentView = view
    panel.backgroundColor = .clear
    panel.isOpaque = false
    panel.hasShadow = true
    panel.level = .floating
    panel.hidesOnDeactivate = false
    panel.isFloatingPanel = true
    panel.becomesKeyOnlyIfNeeded = true
    panel.ignoresMouseEvents = true
    panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
  }

  /// `point` is the bottom-centre the chip should sit on.
  func anchor(at point: NSPoint, animated: Bool) {
    anchor = point
    guard panel.isVisible else { return }
    let frame = frameForCurrentMessage()
    if animated {
      NSAnimationContext.runAnimationGroup { context in
        context.duration = 0.3
        context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        panel.animator().setFrame(frame, display: true)
      }
    } else {
      panel.setFrame(frame, display: true)
    }
  }

  func show(_ message: String, above indicatorFrame: NSRect) {
    anchor = NSPoint(x: indicatorFrame.midX, y: indicatorFrame.maxY + 8)
    // Recording states re-present the same message on every audio level update, so an identical
    // message must not keep resetting the timer or the chip would never leave the screen.
    if message == self.message, panel.isVisible {
      panel.setFrame(frameForCurrentMessage(), display: true)
      return
    }
    self.message = message
    view.message = message
    panel.setFrame(frameForCurrentMessage(), display: true)
    if panel.isVisible == false { panel.alphaValue = 0 }
    panel.orderFrontRegardless()
    NSAnimationContext.runAnimationGroup { context in
      context.duration = ToastUI.fadeDuration
      panel.animator().alphaValue = 1
    }
    dismissal?.invalidate()
    dismissal = Timer.scheduledTimer(withTimeInterval: ToastUI.lifetime, repeats: false) {
      [weak self] _ in
      MainActor.assumeIsolated { self?.dismiss() }
    }
  }

  private func dismiss() {
    dismissal?.invalidate()
    dismissal = nil
    message = nil
    NSAnimationContext.runAnimationGroup { context in
      context.duration = ToastUI.fadeDuration
      panel.animator().alphaValue = 0
    } completionHandler: { [weak panel] in
      MainActor.assumeIsolated { panel?.orderOut(nil) }
    }
  }

  private func frameForCurrentMessage() -> NSRect {
    let size = view.fittingSize
    return NSRect(
      x: anchor.x - size.width / 2, y: anchor.y, width: size.width, height: size.height)
  }
}

@MainActor
private final class ToastPanel: NSPanel {
  override var canBecomeKey: Bool { false }
  override var canBecomeMain: Bool { false }
}

@MainActor
private final class ToastView: NSView {
  private static let horizontalPadding: CGFloat = 16
  private static let verticalPadding: CGFloat = 10

  var message: String = "" {
    didSet {
      setAccessibilityLabel(message)
      invalidateIntrinsicContentSize()
      needsDisplay = true
    }
  }

  override var isFlipped: Bool { true }

  init() {
    super.init(frame: .zero)
    setAccessibilityElement(true)
    setAccessibilityRole(.init(rawValue: "AXGroup"))
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) is unavailable")
  }

  override var intrinsicContentSize: NSSize {
    let text = attributedMessage.size()
    return NSSize(
      width: ceil(text.width) + ToastView.horizontalPadding * 2,
      height: ceil(text.height) + ToastView.verticalPadding * 2
    )
  }

  override var fittingSize: NSSize { intrinsicContentSize }

  override func viewDidChangeEffectiveAppearance() {
    super.viewDidChangeEffectiveAppearance()
    needsDisplay = true
  }

  override func draw(_ dirtyRect: NSRect) {
    super.draw(dirtyRect)
    // Inverting label over text-background gives a dark chip in light appearance and a light chip
    // in dark, without naming a single colour value.
    NSColor.labelColor.setFill()
    NSBezierPath(roundedRect: bounds, xRadius: 9, yRadius: 9).fill()
    let text = attributedMessage
    let size = text.size()
    text.draw(
      at: NSPoint(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2))
  }

  private var attributedMessage: NSAttributedString {
    NSAttributedString(
      string: message,
      attributes: [
        .font: NSFont.systemFont(ofSize: 13, weight: .medium),
        .foregroundColor: NSColor.textBackgroundColor,
      ]
    )
  }
}
