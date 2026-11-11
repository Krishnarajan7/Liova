import LiovaPluginKit
import LiovaUI
import SwiftUI

/// The unlock moment in the closed notch: Liova's face wakes up on the left while light
/// spills out from beside the camera into both sides; on the right, how long you were
/// away comes into focus.
///
/// One-shot, like every closed-notch effect. With Reduce Motion it only fades.
@MainActor
public final class UnlockRenderer: ActivityRenderer {
    private let feature: UnlockFeature

    public init(feature: UnlockFeature) {
        self.feature = feature
    }

    public func compactLeading(for _: Activity) -> AnyView? {
        AnyView(WakingFace(size: 17))
    }

    public func compactTrailing(for _: Activity) -> AnyView? {
        guard let away = feature.lastUnlock?.away.flatMap(UnlockPolicy.awayText) else { return nil }
        return AnyView(AwayTime(text: away))
    }

    public func compactBackground(for _: Activity) -> AnyView? {
        AnyView(Daybreak())
    }

    public func expanded(for _: Activity) -> AnyView? {
        AnyView(WelcomeCard(unlock: feature.lastUnlock))
    }
}

enum UnlockColors {
    /// A cool dawn light: not the blue of charging or headphones, not a system tint.
    static let light = Color(red: 0.55, green: 0.95, blue: 0.85)
}

/// The moment's timeline, in seconds from when it appears. The closed notch's ears only fade
/// in about 0.45 s after an activity starts (`Motion.compactContentIn`), so the face waits
/// for that: it's seen asleep first, then wakes in one motion.
enum UnlockTimeline {
    static let visible: TimeInterval = 0.45
    static let wake: TimeInterval = 0.7
    /// The away time arrives as the smile finishes.
    static let away: TimeInterval = 0.8
    /// Everything settles away just before the notch shrinks (`UnlockPolicy.duration`).
    static let outro: TimeInterval = 2.85
}

/// Liova's face waking up from nothing: a ring draws around, the eyes pop in and the smile
/// spreads from the middle, all as one smooth curve. At the end it fades with the
/// notch. In the open notch's card it wakes and stays.
struct WakingFace: View {
    let size: CGFloat
    /// Fade at the end, with the closed notch. The card stays while it's shown.
    var fades = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var play = false

    struct Frame {
        var awake: CGFloat = 0
        var shown: CGFloat = 1
    }

    var body: some View {
        Group {
            if reduceMotion {
                face(Frame(awake: 1))
            } else {
                KeyframeAnimator(initialValue: Frame(), trigger: play) { frame in
                    face(frame)
                } keyframes: { _ in
                    KeyframeTrack(\.awake) {
                        LinearKeyframe(0, duration: fades ? UnlockTimeline.visible : 0.15)
                        CubicKeyframe(1, duration: UnlockTimeline.wake)
                    }
                    KeyframeTrack(\.shown) {
                        LinearKeyframe(1, duration: UnlockTimeline.outro)
                        CubicKeyframe(fades ? 0 : 1, duration: 0.3)
                    }
                }
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
        .onAppear { play = true }
    }

    /// Each part's share of `awake`, 0 to 1: the ring draws first, the eyes open as it
    /// closes, and the smile finishes last. Nothing shows at 0.
    static func part(_ awake: CGFloat, from start: CGFloat, to end: CGFloat) -> CGFloat {
        min(max((awake - start) / (end - start), 0), 1)
    }

    private func face(_ frame: Frame) -> some View {
        let ring = Self.part(frame.awake, from: 0, to: 0.6)
        let eyes = Self.part(frame.awake, from: 0.4, to: 0.75)
        let smile = Self.part(frame.awake, from: 0.6, to: 1)
        let line = size * 0.075
        let eye = size * 0.13
        return ZStack {
            Circle()
                .trim(from: 0, to: ring)
                .stroke(UnlockColors.light, style: StrokeStyle(lineWidth: line, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .opacity(ring > 0 ? 1 : 0)
            HStack(spacing: size * 0.2) {
                ForEach(0 ..< 2, id: \.self) { _ in
                    Circle()
                        .fill(.white)
                        .frame(width: eye, height: eye)
                        .scaleEffect(eyes)
                }
            }
            .offset(y: -size * 0.09)
            Smile()
                .trim(from: 0.5 - 0.5 * smile, to: 0.5 + 0.5 * smile)
                .stroke(.white, style: StrokeStyle(lineWidth: line, lineCap: .round))
                .frame(width: size * 0.38, height: size * 0.12)
                .offset(y: size * 0.15)
                .opacity(smile > 0 ? 1 : 0)
        }
        .padding(line / 2)
        .shadow(color: UnlockColors.light.opacity(0.5 * ring), radius: size * 0.12)
        .opacity(frame.shown)
        .scaleEffect(0.9 + 0.1 * frame.shown)
    }
}

/// The face's smile: one arc, drawn from its middle outwards by `trim`.
struct Smile: Shape {
    func path(in rect: CGRect) -> Path {
        Path { path in
            path.move(to: CGPoint(x: rect.minX, y: rect.minY))
            path.addQuadCurve(
                to: CGPoint(x: rect.maxX, y: rect.minY),
                control: CGPoint(x: rect.midX, y: rect.maxY + rect.height)
            )
        }
    }
}

/// How long the Mac was locked, coming into focus as the face wakes.
private struct AwayTime: View {
    let text: String
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var play = false

    var body: some View {
        KeyframeAnimator(initialValue: reduceMotion ? 1.0 : 0, trigger: play) { shown in
            Text(text)
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .lineLimit(1)
                .fixedSize()
                .foregroundStyle(.white.opacity(0.9))
                .blur(radius: 4 * (1 - shown))
                .opacity(shown)
                .offset(x: -5 * (1 - shown))
        } keyframes: { _ in
            KeyframeTrack {
                LinearKeyframe(reduceMotion ? 1 : 0, duration: UnlockTimeline.away)
                CubicKeyframe(1, duration: 0.4)
                LinearKeyframe(1, duration: UnlockTimeline.outro - UnlockTimeline.away - 0.4)
                CubicKeyframe(0, duration: 0.25)
            }
        }
        .accessibilityLabel(Text("Away \(text)"))
        .onAppear { play = true }
    }
}

/// Light spilling from under the camera to both sides at once, as if the notch were
/// opening, then fading: a thin line along the bottom edge and a soft glow above it.
private struct Daybreak: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var spread: CGFloat = 0
    @State private var fade: Double = 1

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .bottom) {
                RadialGradient(
                    colors: [UnlockColors.light.opacity(0.35), UnlockColors.light.opacity(0)],
                    center: .bottom, startRadius: 0, endRadius: proxy.size.width * 0.5
                )
                .scaleEffect(x: max(spread, 0.01), y: 1, anchor: .bottom)
                LinearGradient(
                    colors: [UnlockColors.light.opacity(0), UnlockColors.light, UnlockColors.light.opacity(0)],
                    startPoint: .leading, endPoint: .trailing
                )
                .frame(height: 1.5)
                .scaleEffect(x: max(spread, 0.01), y: 1, anchor: .center)
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
            .blendMode(.plusLighter)
            .opacity(reduceMotion ? 0 : fade)
        }
        .allowsHitTesting(false)
        .onAppear {
            withAnimation(.easeOut(duration: 0.8).delay(0.1)) { spread = 1 }
            withAnimation(.easeIn(duration: 0.9).delay(1.2)) { fade = 0 }
        }
    }
}

/// The open notch during the moment.
private struct WelcomeCard: View {
    let unlock: UnlockFeature.Unlock?

    var body: some View {
        HStack(spacing: 14) {
            WakingFace(size: 30, fades: false)
                .frame(width: 44, height: 44)
                .background(Circle().fill(.white.opacity(0.06)))
            VStack(alignment: .leading, spacing: 4) {
                Text(greeting)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                if let detail {
                    Text(detail)
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.5))
                }
            }
            Spacer(minLength: 0)
        }
    }

    private var greeting: String {
        let hour = Calendar.current.component(.hour, from: unlock?.unlockedAt ?? Date())
        switch hour {
        case 5 ..< 12: return "Good morning"
        case 12 ..< 17: return "Good afternoon"
        case 17 ..< 22: return "Good evening"
        default: return "Welcome back"
        }
    }

    /// "Locked at 3:12 PM · away 42m".
    private var detail: String? {
        guard let unlock, let lockedAt = unlock.lockedAt else { return nil }
        let time = lockedAt.formatted(date: .omitted, time: .shortened)
        guard let away = unlock.away.flatMap(UnlockPolicy.awayText) else { return "Locked at \(time)" }
        return "Locked at \(time) · away \(away)"
    }
}
