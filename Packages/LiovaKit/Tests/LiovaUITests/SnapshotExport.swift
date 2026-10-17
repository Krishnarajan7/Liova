import AppKit
import LiovaCore
import LiovaPluginKit
@testable import LiovaUI
import SwiftUI
import Testing

/// Renders every notch state to PNG for visual review, docs and the README.
///
/// Skipped unless `LIOVA_SNAPSHOT_DIR` is set:
/// `LIOVA_SNAPSHOT_DIR=/tmp/liova-snapshots swift test --filter SnapshotExport`
@MainActor
@Suite(.enabled(if: ProcessInfo.processInfo.environment["LIOVA_SNAPSHOT_DIR"] != nil))
struct SnapshotExport {
    let directory = URL(fileURLWithPath: ProcessInfo.processInfo.environment["LIOVA_SNAPSHOT_DIR"] ?? "/tmp")

    let geometry = NotchGeometry(metrics: ScreenMetrics(
        frame: CGRect(x: 0, y: 0, width: 1710, height: 1112),
        visibleFrame: CGRect(x: 0, y: 0, width: 1710, height: 1073),
        safeAreaTop: 38,
        auxiliaryTopLeft: CGRect(x: 0, y: 1074, width: 751, height: 38),
        auxiliaryTopRight: CGRect(x: 960, y: 1074, width: 750, height: 38)
    ))

    @Test func exportStates() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let build = Activity(
            id: "build", source: "cli", title: "Building Liova", subtitle: "Compiling 42 of 120 files",
            symbol: "hammer.fill", progress: 0.35, tint: .blue
        )
        let charging = Activity(
            id: "charge", source: "system.battery", priority: .high, title: "Charging", subtitle: "76%",
            symbol: "bolt.fill", progress: 0.76, tint: .green
        )
        let agent = Activity(
            id: "agent", source: "cli", priority: .low, title: "Claude Code is thinking", symbol: "sparkle",
            tint: .orange
        )

        try render("1-closed-idle", .closed, [])
        try render("2-closed-activity", .closed, [build])
        try render("3-peek-activity", .peek, [charging])
        try render("4-expanded-empty", .expanded, [])
        try render("5-expanded-stack", .expanded, [build, charging, agent])
    }

    let renderers = ActivityRendererRegistry()
    let chrome = NotchChrome()

    private func render(_ name: String, _ presentation: NotchPresentation, _ activities: [Activity]) throws {
        let engine = ActivityEngine()
        for activity in activities {
            try engine.start(activity)
        }
        let model = NotchModel(geometry: geometry, showsIdleVirtualNotch: true)
        model.presentation = presentation
        let size = NotchLayout.panelSize(for: geometry)

        let view = ZStack(alignment: .top) {
            // Stand-in for the menu bar so the shape's edges are visible.
            VStack(spacing: 0) {
                Color(white: 0.85).frame(height: geometry.notchSize.height)
                Color(white: 0.95)
            }
            NotchRootView(model: model, engine: engine, renderers: renderers, chrome: chrome, onTap: {})
        }
        .frame(width: size.width, height: size.height)

        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        let image = try #require(renderer.nsImage)
        let tiff = try #require(image.tiffRepresentation)
        let png = try #require(NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]))
        try png.write(to: directory.appendingPathComponent("\(name).png"))
    }
}
