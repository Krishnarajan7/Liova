import AppKit
import IOKit.ps
import LiovaCore
import SwiftUI

/// A small animated level meter for "music is playing".
///
/// Driven by a display link with continuous motion, capped at 30 fps plugged in and 20 fps
/// on battery: smooth, at a fraction of the system cost of 60 fps. It runs only while music
/// plays, the notch is visible, Low Power Mode is off and `mode` allows it on the current
/// power source; otherwise the bars rest.
public struct EqualizerBars: NSViewRepresentable {
    public var isAnimating: Bool
    public var mode: MusicBarsMode
    public var color: NSColor
    public var barCount: Int

    public init(isAnimating: Bool, mode: MusicBarsMode = .always, color: NSColor, barCount: Int = 4) {
        self.isAnimating = isAnimating
        self.mode = mode
        self.color = color
        self.barCount = barCount
    }

    public func makeNSView(context _: Context) -> EqualizerBarsView {
        EqualizerBarsView(barCount: barCount)
    }

    public func updateNSView(_ view: EqualizerBarsView, context: Context) {
        view.update(color: color, isAnimating: isAnimating && context.environment.notchCompactVisible, mode: mode)
    }
}

public final class EqualizerBarsView: NSView {
    /// Smooth, continuous motion at 30 fps. Measured on a MacBook Air M4 (WindowServer CPU
    /// added while music plays): 60 fps +7.5%, 30 fps +3.7%, 10 discrete steps +4% but
    /// visibly choppy. 30 fps reads as fluid on a 16 pt meter at half the cost of 60.
    static let pluggedInFrameRate = CAFrameRateRange(minimum: 24, maximum: 30, preferred: 30)
    /// On battery, 20 fps: still fluid for a 16 pt meter, about half the cost of 30.
    static let batteryFrameRate = CAFrameRateRange(minimum: 15, maximum: 20, preferred: 20)

    static var isOnBattery: Bool {
        guard let source = IOPSGetProvidingPowerSourceType(nil)?.takeUnretainedValue() else { return false }
        return (source as String) == kIOPMBatteryPowerKey
    }

    nonisolated static let restingLevel: CGFloat = 0.3

    private var bars: [CALayer] = []
    private var isAnimating = false
    private var mode: MusicBarsMode = .always
    private var color: NSColor = .white
    private var link: CADisplayLink?
    private var startTime = CACurrentMediaTime()
    private var observers: [any NSObjectProtocol] = []
    private var powerSource: CFRunLoopSource?

    init(barCount: Int) {
        super.init(frame: .zero)
        wantsLayer = true
        for _ in 0 ..< max(barCount, 1) {
            let bar = CALayer()
            bar.anchorPoint = CGPoint(x: 0.5, y: 0)
            bar.actions = ["transform": NSNull(), "bounds": NSNull(), "position": NSNull()]
            bar.transform = CATransform3DMakeScale(1, Self.restingLevel, 1)
            layer?.addSublayer(bar)
            bars.append(bar)
        }
        // Low Power Mode means the user wants battery over flourish: rest the bars.
        observers.append(NotificationCenter.default.addObserver(
            forName: .NSProcessInfoPowerStateDidChange, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.syncAnimation() }
        })
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    isolated deinit {
        link?.invalidate()
        observers.forEach(NotificationCenter.default.removeObserver)
        if let powerSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), powerSource, .commonModes)
        }
    }

    override public func layout() {
        super.layout()
        let count = CGFloat(bars.count)
        let gap: CGFloat = 2
        let width = max(1.5, (bounds.width - gap * (count - 1)) / count)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (index, bar) in bars.enumerated() {
            bar.bounds = CGRect(x: 0, y: 0, width: width, height: bounds.height)
            bar.position = CGPoint(x: CGFloat(index) * (width + gap) + width / 2, y: 0)
            bar.cornerRadius = width / 2
        }
        CATransaction.commit()
    }

    func update(color: NSColor, isAnimating: Bool, mode: MusicBarsMode) {
        if color != self.color {
            self.color = color
            applyColor()
        }
        guard isAnimating != self.isAnimating || mode != self.mode else { return }
        self.isAnimating = isAnimating
        self.mode = mode
        watchPowerSource(mode != .off)
        syncAnimation()
    }

    /// Plugging in or unplugging changes the frame rate, or whether the bars move at all.
    /// macOS fires this only when the power source state changes, so it costs nothing at rest.
    private func watchPowerSource(_ watch: Bool) {
        guard watch != (powerSource != nil) else { return }
        if let powerSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), powerSource, .commonModes)
            self.powerSource = nil
            return
        }
        let context = Unmanaged.passUnretained(self).toOpaque()
        guard let source = IOPSNotificationCreateRunLoopSource({ context in
            guard let context else { return }
            let view = Unmanaged<EqualizerBarsView>.fromOpaque(context).takeUnretainedValue()
            MainActor.assumeIsolated { view.syncAnimation() }
        }, context)?.takeRetainedValue() else { return }
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        powerSource = source
    }

    override public func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        if let old = window {
            NotificationCenter.default.removeObserver(
                self,
                name: NSWindow.didChangeOcclusionStateNotification,
                object: old
            )
        }
    }

    override public func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        applyColor()
        if let window {
            // Screen asleep, locked or covered: stop drawing frames nobody can see.
            NotificationCenter.default.addObserver(
                self, selector: #selector(occlusionChanged),
                name: NSWindow.didChangeOcclusionStateNotification, object: window
            )
        }
        syncAnimation()
    }

    @objc private func occlusionChanged() {
        syncAnimation()
    }

    private func applyColor() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        bars.forEach { $0.backgroundColor = color.cgColor }
        CATransaction.commit()
    }

    /// Runs the display link only while playing, visible, not in Low Power Mode and allowed
    /// on the current power source.
    private func syncAnimation() {
        let visible = window?.occlusionState.contains(.visible) ?? false
        let onBattery = Self.isOnBattery
        let shouldRun = isAnimating && visible && mode.animates(onBattery: onBattery)
            && !ProcessInfo.processInfo.isLowPowerModeEnabled
        if shouldRun {
            if link == nil {
                let link = displayLink(target: self, selector: #selector(tick))
                link.add(to: .main, forMode: .common)
                self.link = link
            }
            link?.preferredFrameRateRange = onBattery ? Self.batteryFrameRate : Self.pluggedInFrameRate
            link?.isPaused = false
        } else {
            link?.isPaused = true
            setLevels(Array(repeating: Self.restingLevel, count: bars.count))
        }
    }

    @objc private func tick() {
        setLevels(Self.levels(at: CACurrentMediaTime() - startTime, count: bars.count))
    }

    private func setLevels(_ levels: [CGFloat]) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (bar, level) in zip(bars, levels) {
            bar.transform = CATransform3DMakeScale(1, level, 1)
        }
        CATransaction.commit()
    }

    /// Bar heights at a moment: two overlapping waves per bar with different speeds, so the
    /// motion is continuous (smooth at any frame rate) yet never looks mechanical.
    nonisolated static func levels(at time: Double, count: Int) -> [CGFloat] {
        (0 ..< count).map { index in
            let seed = Double(index) * 1.7
            let wave = sin(time * (5.1 + seed) + seed) * 0.5 + sin(time * (8.3 - seed * 0.6) + seed * 2) * 0.3
            let normalized = (wave + 0.8) / 1.6 // roughly 0…1
            return CGFloat(min(max(0.25 + normalized * 0.75, 0.2), 1))
        }
    }
}
