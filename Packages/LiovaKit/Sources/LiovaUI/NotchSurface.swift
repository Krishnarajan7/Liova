import AppKit
import LiovaCore
import SwiftUI

/// What the notch is drawn on: black, or glass once open.
///
/// Closed, it's black in both styles: glass around the camera housing would outline the
/// housing instead of hiding it. Opening, the black fades out as the content arrives and
/// the glass shows through; closing, it comes back before the shape shrinks.
struct NotchSurface: View {
    let style: NotchStyle
    let isExpanded: Bool
    let shape: NotchShape

    var body: some View {
        ZStack {
            if style == .glass {
                NotchGlass(shape: shape)
            }
            shape
                .fill(.black)
                .opacity(style == .glass && isExpanded ? 0 : 1)
                .animation(isExpanded ? Motion.expandedContentIn : Motion.contentOut, value: isExpanded)
        }
    }
}

/// Liquid Glass on macOS 26, a behind-window blur before it.
///
/// Clear glass, as on iPhone: the desktop shows through bright and sharp-edged, bent at the
/// rim, and the glass responds to the pointer. A light dim keeps white text readable over a
/// bright desktop, and the camera row fades to black so the glass grows out of the housing
/// instead of framing it.
private struct NotchGlass: View {
    let shape: NotchShape

    static let dim = Color.black.opacity(0.18)

    var body: some View {
        Group {
            if #available(macOS 26, *) {
                Color.clear
                    .glassEffect(.clear.tint(Self.dim).interactive(), in: shape)
            } else {
                BehindWindowBlur()
                    .overlay(Self.dim)
                    .clipShape(shape)
            }
        }
        .overlay(alignment: .top) {
            LinearGradient(
                stops: [
                    .init(color: .black.opacity(0.9), location: 0),
                    .init(color: .black.opacity(0.35), location: 0.18),
                    .init(color: .clear, location: 0.4),
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .clipShape(shape)
            .allowsHitTesting(false)
        }
    }
}

/// One `NSVisualEffectView` blurring the desktop behind the panel (performance rule 7).
private struct BehindWindowBlur: NSViewRepresentable {
    func makeNSView(context _: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .hudWindow
        view.blendingMode = .behindWindow
        // The notch's panel is never key; without this the blur would look inactive.
        view.state = .active
        return view
    }

    func updateNSView(_: NSVisualEffectView, context _: Context) {}
}
