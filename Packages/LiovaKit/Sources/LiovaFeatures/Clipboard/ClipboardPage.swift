import AppKit
import ImageIO
import LiovaProviders
import LiovaUI
import SwiftUI

/// The Clipboard page: what you copied lately as a row of cards, newest first. Click one to
/// copy it again, drag it out to drop it anywhere, pin what you reuse.
public struct ClipboardPage: View {
    let feature: ClipboardFeature

    public init(feature: ClipboardFeature) {
        self.feature = feature
    }

    public var body: some View {
        Group {
            if feature.items.isEmpty {
                EmptyClipboard()
                    .transition(.opacity)
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("Click to copy · drag to drop anywhere")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.5))
                        Spacer()
                        if feature.items.contains(where: { !$0.isPinned }) {
                            Button("Clear") { withAnimation(Motion.list) { feature.clear() } }
                                .buttonStyle(.plain)
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(.white.opacity(0.5))
                        }
                    }
                    ScrollView(.horizontal, showsIndicators: false) {
                        LazyHStack(spacing: 8) {
                            ForEach(feature.items) { item in
                                ClipboardCard(item: item, feature: feature)
                                    .transition(Motion.listItem)
                            }
                        }
                        .animation(Motion.list, value: feature.items.map(\.id))
                    }
                }
                .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .animation(Motion.list, value: feature.items.isEmpty)
    }
}

private struct EmptyClipboard: View {
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "doc.on.clipboard")
                .font(.system(size: 20, weight: .medium))
                .foregroundStyle(.white.opacity(0.5))
            VStack(alignment: .leading, spacing: 2) {
                Text("Nothing copied yet")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                Text("Copy text, links, images or files and they'll wait here. Passwords are never kept.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.white.opacity(0.55))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// One copied thing: a preview, where it came from and when.
private struct ClipboardCard: View {
    let item: ClipboardItem
    let feature: ClipboardFeature
    @State private var isHovered = false

    var body: some View {
        let copied = feature.justCopied == item.id
        VStack(alignment: .leading, spacing: 5) {
            ClipboardPreview(item: item)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            HStack(spacing: 4) {
                if let icon = ClipboardText.appIcon(item.sourceBundleID) {
                    Image(nsImage: icon)
                        .resizable()
                        .frame(width: 12, height: 12)
                }
                Text(ClipboardText.age(item.copiedAt))
                    .lineLimit(1)
                Spacer(minLength: 0)
                if item.isPinned {
                    Image(systemName: "pin.fill")
                        .foregroundStyle(.yellow)
                }
            }
            .font(.system(size: 9.5, weight: .medium))
            .foregroundStyle(.white.opacity(0.45))
        }
        .padding(8)
        .frame(width: 128, height: 96)
        .clipped()
        .background(.white.opacity(isHovered ? 0.13 : 0.07), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
            if copied {
                Label("Copied", systemImage: "checkmark.circle.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(.black.opacity(0.7), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .transition(.opacity)
            }
        }
        .overlay(alignment: .topTrailing) {
            if isHovered, !copied {
                CardActions(item: item, feature: feature)
                    .transition(.opacity)
            }
        }
        .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .animation(Motion.list, value: copied)
        .animation(.easeOut(duration: 0.15), value: isHovered)
        .onHover { isHovered = $0 }
        .onTapGesture { feature.copy(item) }
        .onDrag { ClipboardText.provider(for: item.content) }
        .contextMenu {
            Button("Copy") { feature.copy(item) }
            Button(item.isPinned ? "Unpin" : "Pin") { withAnimation(Motion.list) { feature.togglePin(item) } }
            Divider()
            Button("Delete") { withAnimation(Motion.list) { feature.remove(item) } }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityHint("Copies it again")
    }
}

private struct CardActions: View {
    let item: ClipboardItem
    let feature: ClipboardFeature

    var body: some View {
        HStack(spacing: 2) {
            button(
                item.isPinned ? "pin.slash.fill" : "pin.fill",
                help: item.isPinned ? "Unpin" : "Keep it, even after Liova quits"
            ) {
                feature.togglePin(item)
            }
            button("xmark", help: "Delete") { feature.remove(item) }
        }
        .padding(4)
    }

    private func button(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button { withAnimation(Motion.list) { action() } } label: {
            Image(systemName: symbol)
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 18, height: 18)
                .background(.black.opacity(0.6), in: Circle())
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

/// What the card shows of the copied thing.
private struct ClipboardPreview: View {
    let item: ClipboardItem

    var body: some View {
        switch item.content {
        case let .text(text):
            Text(text.trimmingCharacters(in: .whitespacesAndNewlines))
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.9))
                .lineLimit(4)
        case let .link(url):
            VStack(alignment: .leading, spacing: 3) {
                Label(url.host() ?? url.absoluteString, systemImage: "link")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.blue)
                    .lineLimit(1)
                Text(url.path().isEmpty || url.path() == "/" ? url.absoluteString : url.path())
                    .font(.system(size: 10))
                    .foregroundStyle(.white.opacity(0.55))
                    .lineLimit(2)
                    .truncationMode(.middle)
            }
        case let .image(data, _):
            if let image = ClipboardText.thumbnail(item.id, data) {
                // Fills the space the card gives it and is cropped there: on its own, a
                // filled image takes its full width and spills over the next card.
                Color.clear
                    .overlay {
                        Image(nsImage: image)
                            .resizable()
                            .scaledToFill()
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            } else {
                Label("Image", systemImage: "photo")
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.7))
            }
        case let .files(urls):
            HStack(spacing: 6) {
                Image(nsImage: NSWorkspace.shared.icon(forFile: urls[0].path))
                    .resizable()
                    .frame(width: 28, height: 28)
                Text(urls.count == 1 ? urls[0].lastPathComponent : "\(urls.count) files")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white.opacity(0.9))
                    .lineLimit(2)
                    .truncationMode(.middle)
            }
        }
    }
}

/// Small helpers for the cards.
enum ClipboardText {
    /// "now", "4 min ago", "2 hr ago": when the page opens; it isn't a live clock.
    static func age(_ date: Date, now: Date = Date()) -> String {
        let seconds = now.timeIntervalSince(date)
        guard seconds >= 60 else { return "now" }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: now)
    }

    static func appIcon(_ bundleID: String?) -> NSImage? {
        guard let bundleID, let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
            return nil
        }
        return NSWorkspace.shared.icon(forFile: url.path)
    }

    /// Small copies of images, made once: decoding the full image on every redraw would be slow.
    @MainActor private static let thumbnails = NSCache<NSUUID, NSImage>()

    @MainActor
    static func thumbnail(_ id: UUID, _ data: Data) -> NSImage? {
        if let cached = thumbnails.object(forKey: id as NSUUID) {
            return cached
        }
        let options = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: 240,
            kCGImageSourceCreateThumbnailWithTransform: true,
        ] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options)
        else { return nil }
        let image = NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
        thumbnails.setObject(image, forKey: id as NSUUID)
        return image
    }

    static func provider(for content: ClipboardContent) -> NSItemProvider {
        switch content {
        case let .text(text):
            NSItemProvider(object: text as NSString)
        case let .link(url):
            NSItemProvider(object: url as NSURL)
        case let .image(data, _):
            NSImage(data: data).map { NSItemProvider(object: $0) } ?? NSItemProvider()
        case let .files(urls):
            NSItemProvider(contentsOf: urls[0]) ?? NSItemProvider()
        }
    }
}
