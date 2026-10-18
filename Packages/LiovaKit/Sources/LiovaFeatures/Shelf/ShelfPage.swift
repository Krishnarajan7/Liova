import AppKit
import LiovaUI
import SwiftUI
import UniformTypeIdentifiers

/// The Shelf page. While files are dragged onto the notch it shows two drop zones,
/// "Keep on Shelf" and "AirDrop"; otherwise it shows the kept files as draggable tiles.
public struct ShelfPage: View {
    let feature: ShelfFeature
    @Environment(\.notchFileDragActive) private var isDragging

    public init(feature: ShelfFeature) {
        self.feature = feature
    }

    public var body: some View {
        Group {
            if isDragging {
                HStack(spacing: 10) {
                    DropZone(title: "Keep on Shelf", symbol: "tray.and.arrow.down.fill", tint: .white) { urls in
                        withAnimation(Motion.list) { _ = feature.add(urls) }
                    }
                    DropZone(title: "AirDrop", symbol: "dot.radiowaves.left.and.right", tint: .blue) { urls in
                        feature.airDrop(urls: urls)
                    }
                    .frame(width: 130)
                }
                .transition(.opacity.combined(with: .scale(scale: 0.97)))
            } else if feature.items.isEmpty {
                EmptyShelf()
                    .transition(.opacity)
            } else {
                ShelfContents(feature: feature)
                    .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .animation(.spring(response: 0.3, dampingFraction: 0.85), value: isDragging)
        .animation(.spring(response: 0.3, dampingFraction: 0.85), value: feature.items.isEmpty)
    }
}

/// A target for dropped files that lights up while files hover over it.
private struct DropZone: View {
    let title: String
    let symbol: String
    let tint: Color
    let onDrop: ([URL]) -> Void
    @State private var isTargeted = false

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: symbol)
                .font(.system(size: 20, weight: .semibold))
                .symbolEffect(.bounce, value: isTargeted)
            Text(title)
                .font(.system(size: 12, weight: .semibold))
        }
        .foregroundStyle(isTargeted ? tint : .white.opacity(0.6))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(tint.opacity(isTargeted ? 0.16 : 0.05))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(
                            tint.opacity(isTargeted ? 0.8 : 0.25),
                            style: StrokeStyle(lineWidth: 1.5, dash: [5, 4])
                        )
                )
        }
        .scaleEffect(isTargeted ? 1.02 : 1)
        .animation(.spring(response: 0.25, dampingFraction: 0.75), value: isTargeted)
        .onDrop(of: [.fileURL], isTargeted: $isTargeted) { providers in
            Task { @MainActor in
                let urls = await Self.urls(from: providers)
                if !urls.isEmpty {
                    onDrop(urls)
                }
            }
            return true
        }
    }

    static func urls(from providers: [NSItemProvider]) async -> [URL] {
        var urls: [URL] = []
        for provider in providers where provider.canLoadObject(ofClass: URL.self) {
            if let url = await withCheckedContinuation({ (continuation: CheckedContinuation<URL?, Never>) in
                _ = provider.loadObject(ofClass: URL.self) { url, _ in continuation.resume(returning: url) }
            }) {
                urls.append(url)
            }
        }
        return urls
    }
}

private struct EmptyShelf: View {
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "tray")
                .font(.system(size: 20, weight: .medium))
                .foregroundStyle(.white.opacity(0.5))
            VStack(alignment: .leading, spacing: 2) {
                Text("Your Shelf is empty")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                Text("Drag files onto the notch to keep them handy, then drag them out anywhere.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.white.opacity(0.55))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct ShelfContents: View {
    let feature: ShelfFeature

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("\(feature.items.count) item\(feature.items.count == 1 ? "" : "s")")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.5))
                Spacer()
                Button {
                    feature.airDrop()
                } label: {
                    Label("AirDrop All", systemImage: "dot.radiowaves.left.and.right")
                        .font(.system(size: 11, weight: .semibold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.blue)
                Button("Clear") { withAnimation(Motion.list) { feature.clear() } }
                    .buttonStyle(.plain)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white.opacity(0.5))
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(feature.items) { item in
                        ShelfTile(item: item, feature: feature)
                            .transition(Motion.listItem)
                    }
                }
                .animation(Motion.list, value: feature.items.map(\.id))
            }
        }
    }
}

/// One kept file: its icon and name. Drag it out to use it anywhere.
private struct ShelfTile: View {
    let item: ShelfItem
    let feature: ShelfFeature
    @State private var isHovered = false

    var body: some View {
        let url = feature.url(for: item)
        VStack(spacing: 4) {
            Image(nsImage: url.map { NSWorkspace.shared.icon(forFile: $0.path) } ?? NSImage(
                systemSymbolName: "questionmark.square.dashed", accessibilityDescription: nil
            ) ?? NSImage())
                .resizable()
                .scaledToFit()
                .frame(width: 40, height: 40)
                .opacity(url == nil ? 0.4 : 1)
            Text(item.name)
                .font(.system(size: 10))
                .foregroundStyle(.white.opacity(url == nil ? 0.4 : 0.85))
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .truncationMode(.middle)
                .frame(width: 64)
        }
        .padding(6)
        .background(.white.opacity(isHovered ? 0.1 : 0), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay(alignment: .topTrailing) {
            if isHovered {
                Button { withAnimation(Motion.list) { feature.remove(item.id) } } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 13))
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white, .gray.opacity(0.8))
                }
                .buttonStyle(.plain)
                .offset(x: 4, y: -4)
            }
        }
        .onHover { isHovered = $0 }
        .onDrag {
            guard let url else { return NSItemProvider() }
            return NSItemProvider(contentsOf: url) ?? NSItemProvider()
        }
        .onTapGesture(count: 2) { feature.open(item) }
        .contextMenu {
            Button("Open") { feature.open(item) }
            Button("Show in Finder") { feature.revealInFinder(item) }
            Button("AirDrop") { feature.airDrop([item]) }
            Divider()
            Button("Remove from Shelf") { withAnimation(Motion.list) { feature.remove(item.id) } }
        }
        .help(url?.path ?? "\(item.name) can't be found")
    }
}
