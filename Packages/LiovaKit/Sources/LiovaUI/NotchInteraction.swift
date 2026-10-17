/// The pointer and click state machine for one notch. Pure and synchronous: it returns
/// the timers to start or cancel, and the controller runs them.
public struct NotchInteraction: Equatable, Sendable {
    public enum Event: Equatable, Sendable {
        case pointerEntered
        case pointerExited
        /// The hover-to-open delay elapsed with the pointer still inside.
        case openIntentElapsed
        /// The close grace period elapsed with the pointer still outside.
        case closeIntentElapsed
        case clicked
        case clickedOutside
        /// Something needs the user (e.g. an agent asking for permission): open by itself.
        case attentionRequested
        /// It no longer does: close again if we opened for it and the pointer isn't here.
        case attentionCleared
    }

    public enum Effect: Equatable, Sendable {
        case scheduleOpen
        case cancelOpen
        case scheduleClose
        case cancelClose
        case haptic
    }

    public private(set) var presentation: NotchPresentation = .closed
    public private(set) var isPointerInside = false
    /// True while the notch is open because of `attentionRequested` rather than the user.
    public private(set) var isOpenForAttention = false

    public init() {}

    public mutating func handle(_ event: Event, openOnHover: Bool) -> [Effect] {
        switch event {
        case .pointerEntered: pointerEntered(openOnHover: openOnHover)
        case .pointerExited: pointerExited()
        case .openIntentElapsed, .closeIntentElapsed, .clicked, .clickedOutside: intent(event)
        case .attentionRequested: attentionRequested()
        case .attentionCleared: attentionCleared()
        }
    }

    private mutating func attentionRequested() -> [Effect] {
        guard presentation != .expanded else { return [] }
        presentation = .expanded
        isOpenForAttention = true
        return [.cancelOpen, .cancelClose]
    }

    private mutating func attentionCleared() -> [Effect] {
        defer { isOpenForAttention = false }
        guard isOpenForAttention, presentation == .expanded, !isPointerInside else { return [] }
        presentation = .closed
        return [.cancelClose]
    }

    private mutating func pointerEntered(openOnHover: Bool) -> [Effect] {
        isPointerInside = true
        // The user came to the notch; from now on it behaves as if they opened it.
        isOpenForAttention = false
        guard presentation == .closed else { return [.cancelClose] }
        if openOnHover {
            // Stay closed while the pointer dwells, then open in one motion. Chaining a
            // peek into an open would be two animations, and the hand-off reads as a hitch.
            return [.cancelClose, .scheduleOpen]
        }
        // Click to open: a small peek acknowledges the hover and invites the click.
        presentation = .peek
        return [.cancelClose, .haptic]
    }

    private mutating func pointerExited() -> [Effect] {
        isPointerInside = false
        switch presentation {
        case .peek:
            presentation = .closed
            return [.cancelOpen]
        case .expanded:
            return [.scheduleClose]
        case .closed:
            return [.cancelOpen]
        }
    }

    private mutating func intent(_ event: Event) -> [Effect] {
        switch (event, presentation) {
        case (.openIntentElapsed, .closed) where isPointerInside,
             (.openIntentElapsed, .peek) where isPointerInside:
            presentation = .expanded
            return [.haptic]

        case (.closeIntentElapsed, .expanded) where !isPointerInside:
            presentation = .closed
            return []

        case (.clicked, .closed), (.clicked, .peek):
            presentation = .expanded
            return [.cancelOpen, .cancelClose]

        case (.clickedOutside, .expanded):
            presentation = .closed
            return [.cancelClose]

        default:
            return []
        }
    }
}
