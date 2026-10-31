import AppKit
import IOKit.ps
import LiovaCore
import SwiftUI

/// A small rippling line for "music is playing", tinted by the caller (Now Playing uses a
/// colour from the album art). Paused or resting, it holds still as a gentle curve.
///
/// Driven by a display link with continuous motion, capped at 30 fps plugged in and 20 fps
/// on battery: smooth, at a fraction of the system cost of 60 fps. It runs only while music
/// plays, the notch is visible, Low Power Mode is off and `mode` allows it on the current
/// power source; otherwise the line rests.
///
/// It heals itself: a display link can go quiet after sleep or a display change, and macOS
/// doesn't always say the window is visible again after waking. So while music plays a
/// slow check makes sure the line is doing what it should, and wake or a display
/// change starts them over.
public struct MusicWave: NSViewRepresentable {
    public var isAnimating: Bool
    public var mode: MusicBarsMode
    public var color: NSColor

    public init(isAnimating: Bool, mode: MusicBarsMode = .always, color: NSColor) {
        self.isAnimating = isAnimating
        self.mode = mode
        self.color = color
    }

    public func makeNSView(context _: Context) -> MusicWaveView {
        MusicWaveView()
    }

    public func updateNSView(_ view: MusicWaveView, context: Context) {
        view.update(color: color, isAnimating: isAnimating && context.environment.notchCompactVisible, mode: mode)
    }
}

public final class MusicWaveView: NSView {
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

    /// Points sampled along the line; enough for a smooth curve 24 pt wide.
    nonisolated static let sampleCount = 24
    /// The moment the resting curve is taken from, at the amplitude it rests at.
    nonisolated static let restingTime: Double = 0.9
    nonisolated static let restingAmplitude: CGFloat = 0.45
    static let lineWidth: CGFloat = 2
    /// How often, while music plays, the line checks it.s in the right state.
    static let checkInterval: TimeInterval = 4
    /// A running link that hasn't ticked for this long has gone quiet.
    nonisolated static let stallAfter: CFTimeInterval = 1

    private let line = CAShapeLayer()
    private var isAnimating = false
    private var mode: MusicBarsMode = .always
    private var color: NSColor = .white
    private var link: CADisplayLink?
    private var startTime = CACurrentMediaTime()
    private var observers: [(center: NotificationCenter, token: any NSObjectProtocol)] = []
    private var powerSource: CFRunLoopSource?
    private var lastTick: CFTimeInterval = 0
    private var checkTimer: Timer?

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        line.fillColor = nil
        line.lineWidth = Self.lineWidth
        line.lineCap = .round
        line.lineJoin = .round
        // The path changes every frame and must not animate; the colour may (a new song).
        line.actions = ["path": NSNull(), "bounds": NSNull(), "position": NSNull()]
        layer?.addSublayer(line)
        // Low Power Mode means the user wants battery over flourish: rest the line.
        observers.append((NotificationCenter.default, NotificationCenter.default.addObserver(
            forName: .NSProcessInfoPowerStateDidChange, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.syncAnimation() }
        }))
        // After sleep, unlocking or a display change, start the link over.
        let workspace = NSWorkspace.shared.notificationCenter
        for name in [
            NSWorkspace.didWakeNotification,
            NSWorkspace.screensDidWakeNotification,
            NSWorkspace.sessionDidBecomeActiveNotification,
        ] {
            let token = workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.restartAnimation() }
            }
            observers.append((workspace, token))
        }
        observers.append((NotificationCenter.default, NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.restartAnimation() }
        }))
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    isolated deinit {
        link?.invalidate()
        checkTimer?.invalidate()
        for observer in observers {
            observer.center.removeObserver(observer.token)
        }
        if let powerSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), powerSource, .commonModes)
        }
    }

    override public func layout() {
        super.layout()
        line.frame = bounds
        line.contentsScale = window?.backingScaleFactor ?? 2
        if !isLinkRunning {
            rest()
        }
    }

    func update(color: NSColor, isAnimating: Bool, mode: MusicBarsMode) {
        if color != self.color {
            self.color = color
            applyColor()
        }
        guard isAnimating != self.isAnimating || mode != self.mode else {
            if Self.hasStalled(isRunning: isLinkRunning, lastTick: lastTick, now: CACurrentMediaTime()) {
                restartAnimation()
            }
            return
        }
        self.isAnimating = isAnimating
        self.mode = mode
        watchPowerSource(mode != .off)
        syncAnimation()
    }

    /// Plugging in or unplugging changes the frame rate, or whether the line moves at all.
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
            let view = Unmanaged<MusicWaveView>.fromOpaque(context).takeUnretainedValue()
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
        if newWindow == nil {
            // Off screen for good: a link left behind would keep its display awake.
            link?.invalidate()
            link = nil
            watchHealth(false)
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
        // A link made for the old window's display may not tick on the new one.
        restartAnimation()
    }

    @objc private func occlusionChanged() {
        syncAnimation()
    }

    /// A new song's colour fades in rather than snapping.
    private func applyColor() {
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.4)
        line.strokeColor = color.cgColor
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
            if link?.isPaused ?? true {
                // Counts from now, so the stall check gives a resumed link time to tick.
                lastTick = CACurrentMediaTime()
            }
            link?.preferredFrameRateRange = onBattery ? Self.batteryFrameRate : Self.pluggedInFrameRate
            link?.isPaused = false
        } else {
            link?.isPaused = true
            rest()
        }
        watchHealth(isAnimating && window != nil && mode != .off)
    }

    /// Throws the link away and decides afresh: after wake or a display change, an old
    /// link can stay quiet, and the window's visibility may have changed unannounced.
    private func restartAnimation() {
        link?.invalidate()
        link = nil
        syncAnimation()
    }

    /// While music plays, every few seconds: is the link ticking, and is it running when
    /// it should be? Fixes whichever isn't. Off while paused, so it costs nothing at rest.
    private func watchHealth(_ watch: Bool) {
        guard watch != (checkTimer != nil) else { return }
        guard watch else {
            checkTimer?.invalidate()
            checkTimer = nil
            return
        }
        let timer = Timer(timeInterval: Self.checkInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.healIfStalled() }
        }
        timer.tolerance = Self.checkInterval / 2
        RunLoop.main.add(timer, forMode: .common)
        checkTimer = timer
    }

    private var isLinkRunning: Bool {
        link.map { !$0.isPaused } ?? false
    }

    private func healIfStalled() {
        if Self.hasStalled(isRunning: isLinkRunning, lastTick: lastTick, now: CACurrentMediaTime()) {
            Log.display.notice("Music wave: display link went quiet, restarting")
            restartAnimation()
        } else {
            // Catches a missed "visible again" after wake: resumes if it should be running.
            syncAnimation()
        }
    }

    /// A running link that hasn't ticked in a while has gone quiet. Pure, so it's tested.
    nonisolated static func hasStalled(isRunning: Bool, lastTick: CFTimeInterval, now: CFTimeInterval) -> Bool {
        isRunning && now - lastTick > stallAfter
    }

    @objc private func tick() {
        lastTick = CACurrentMediaTime()
        draw(Self.offsets(at: CACurrentMediaTime() - startTime, count: Self.sampleCount))
    }

    /// Still, as a soft curve: paused, hidden, Low Power Mode or turned off.
    private func rest() {
        let offsets = Self.offsets(at: Self.restingTime, count: Self.sampleCount)
        draw(offsets.map { $0 * Self.restingAmplitude })
    }

    /// Draws `offsets` (−1…1 from the middle) as a smooth line across the view.
    private func draw(_ offsets: [CGFloat]) {
        guard offsets.count > 1, bounds.width > 0 else { return }
        let inset = Self.lineWidth / 2
        let step = (bounds.width - 2 * inset) / CGFloat(offsets.count - 1)
        let half = bounds.height / 2 - inset
        let points = offsets.enumerated().map { index, offset in
            CGPoint(x: inset + CGFloat(index) * step, y: bounds.midY + offset * half)
        }
        // Through the midpoints, with each sample as a control point: smooth, no overshoot.
        let path = CGMutablePath()
        path.move(to: points[0])
        for index in 1 ..< points.count - 1 {
            let (here, next) = (points[index], points[index + 1])
            path.addQuadCurve(to: CGPoint(x: (here.x + next.x) / 2, y: (here.y + next.y) / 2), control: here)
        }
        path.addLine(to: points[points.count - 1])
        line.path = path
    }

    /// The line's height along its length at a moment, −1…1 from the middle: two travelling
    /// waves under an envelope that pins both ends to the middle, with a slowly breathing
    /// amplitude. Continuous in time, so it's smooth at any frame rate, and never repeats
    /// exactly, so it doesn't look mechanical.
    nonisolated static func offsets(at time: Double, count: Int) -> [CGFloat] {
        let amplitude = 0.55 + 0.45 * (0.5 + 0.5 * sin(time * 1.3)) * (0.6 + 0.4 * sin(time * 2.1 + 0.7))
        return (0 ..< count).map { index in
            let x = count > 1 ? Double(index) / Double(count - 1) : 0.5
            let envelope = pow(sin(Double.pi * x), 1.5)
            let wave = 0.6 * sin(2 * .pi * 1.6 * x - time * 4.2) + 0.4 * sin(2 * .pi * 2.7 * x + time * 2.9 + 1.3)
            return CGFloat(min(max(envelope * amplitude * wave, -1), 1))
        }
    }
}
