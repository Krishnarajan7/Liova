import SwiftUI

/// The open notch's frame around the content: pages (tabs), the status shown beside the
/// camera, and actions like opening Settings. The app fills it once at launch.
///
/// Like `ActivityRendererRegistry`, this keeps feature views out of `LiovaUI`: a feature
/// contributes a page or a status view without the notch knowing what it is.
@MainActor
public final class NotchChrome {
    public struct Page: Identifiable {
        public let id: String
        public let symbol: String
        public let title: String
        let content: () -> AnyView

        public init(id: String, symbol: String, title: String, content: @escaping () -> AnyView) {
            self.id = id
            self.symbol = symbol
            self.title = title
            self.content = content
        }
    }

    /// The built-in page: live activities.
    public static let homePageID = "home"

    public private(set) var pages: [Page] = []
    /// Shown right of the camera when no brief event is (e.g. battery level).
    public var trailingStatus: (() -> AnyView)?
    public var openSettings: (() -> Void)?

    public init() {}

    public func addPage(_ page: Page) {
        pages.removeAll { $0.id == page.id }
        pages.append(page)
    }

    var allPageIDs: [String] {
        [Self.homePageID] + pages.map(\.id)
    }
}
