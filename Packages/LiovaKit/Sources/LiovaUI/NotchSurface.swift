import AppKit
import LiovaCore
import SwiftUI

/// What the notch is drawn on: black, or glass once open.
///
/// Closed, it's black in both styles: glass around the camera housing would outline the
/// housing instead of hiding it. In the glass style that black is a cover the size of the
/// closed notch, and it never grows or shrinks with the open notch: the glass grows out
/// from under it and shrinks back to it, and the cover only fades. A black shape that
/// travelled with the glass read as a second animation running ahead of or behind it.
struct NotchSurface: View {
    let style: NotchStyle
    let isExpanded: Bool
    let shape: NotchShape
    /// The closed notch (or the peeking one): what stays black in the glass style.
    let cover: NotchSpec

    var body: some View {
        ZStack(alignment: .top) {
            if style == .glass {
                NotchGlass(shape: shape)
                NotchShape(topRadius: cover.topRadius, bottomRadius: cover.bottomRadius)
                    .fill(.black)
                    .frame(width: cover.shapeWidth, height: cover.height)
                    .opacity(isExpanded ? 0 : 1)
                    .animation(isExpanded ? Motion.surfaceOpen : Motion.surfaceClose, value: isExpanded)
            } else {
                shape.fill(.black)
            }
        }
    }
}

/// Liquid Glass on macOS 26, a behind-window blur before it.
///
/// On macOS 26 it's the system's clear glass and nothing else, as in Control Center: the
/// desktop shows through, bent and lit at the rim, and the glass responds to the pointer.
/// Anything painted over it (a dim, a dark band along the camera row) makes it read as
/// smoked plastic, and the camera housing sits in clear glass cleanly without one.
///
/// The blur before macOS 26 is flatter and brighter, so it keeps a light dim for white
/// text, and fades to black along the camera row.
private struct NotchGlass: View {
    let shape: NotchShape

    static let dim = Color.black.opacity(0.18)

    var body: some View {
        if #available(macOS 26, *) {
            Color.clear
                .glassEffect(.clear.interactive(), in: shape)
        } else {
            BehindWindowBlur()
                .overlay(Self.dim)
                .clipShape(shape)
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
