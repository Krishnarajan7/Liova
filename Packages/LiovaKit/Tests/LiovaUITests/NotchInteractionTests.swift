import LiovaUI
import Testing

struct NotchInteractionTests {
    @Test func hoverOpensInOneMotionAfterIntent() {
        var machine = NotchInteraction()
        let effects = machine.handle(.pointerEntered, openOnHover: true)
        // No intermediate peek: one animation, not two chained.
        #expect(machine.presentation == .closed)
        #expect(effects.contains(.scheduleOpen))
        let opened = machine.handle(.openIntentElapsed, openOnHover: true)
        #expect(machine.presentation == .expanded)
        #expect(opened == [.haptic])
    }

    @Test func leavingBeforeIntentCancelsOpen() {
        var machine = NotchInteraction()
        _ = machine.handle(.pointerEntered, openOnHover: true)
        let effects = machine.handle(.pointerExited, openOnHover: true)
        #expect(machine.presentation == .closed)
        #expect(effects == [.cancelOpen])
    }

    @Test func passingPointerNeverChangesTheNotch() {
        var machine = NotchInteraction()
        _ = machine.handle(.pointerEntered, openOnHover: true)
        _ = machine.handle(.pointerExited, openOnHover: true)
        #expect(machine.presentation == .closed)
        _ = machine.handle(.openIntentElapsed, openOnHover: true)
        #expect(machine.presentation == .closed)
    }

    @Test func staleOpenIntentIsIgnored() {
        var machine = NotchInteraction()
        _ = machine.handle(.pointerEntered, openOnHover: true)
        _ = machine.handle(.pointerExited, openOnHover: true)
        _ = machine.handle(.openIntentElapsed, openOnHover: true)
        #expect(machine.presentation == .closed)
    }

    @Test func hoverDisabledOnlyPeeks() {
        var machine = NotchInteraction()
        let effects = machine.handle(.pointerEntered, openOnHover: false)
        #expect(machine.presentation == .peek)
        #expect(!effects.contains(.scheduleOpen))
        _ = machine.handle(.clicked, openOnHover: false)
        #expect(machine.presentation == .expanded)
    }

    @Test func expandedClosesOnlyAfterGracePeriodOutside() {
        var machine = NotchInteraction()
        _ = machine.handle(.clicked, openOnHover: true)
        let effects = machine.handle(.pointerExited, openOnHover: true)
        #expect(effects == [.scheduleClose])
        #expect(machine.presentation == .expanded)
        _ = machine.handle(.closeIntentElapsed, openOnHover: true)
        #expect(machine.presentation == .closed)
    }

    @Test func reenteringCancelsClose() {
        var machine = NotchInteraction()
        _ = machine.handle(.clicked, openOnHover: true)
        _ = machine.handle(.pointerExited, openOnHover: true)
        let effects = machine.handle(.pointerEntered, openOnHover: true)
        #expect(effects == [.cancelClose])
        _ = machine.handle(.closeIntentElapsed, openOnHover: true)
        #expect(machine.presentation == .expanded)
    }

    @Test func clickOutsideClosesImmediately() {
        var machine = NotchInteraction()
        _ = machine.handle(.clicked, openOnHover: true)
        _ = machine.handle(.clickedOutside, openOnHover: true)
        #expect(machine.presentation == .closed)
    }

    @Test func attentionOpensAndClosesWhenUntouched() {
        var machine = NotchInteraction()
        _ = machine.handle(.attentionRequested, openOnHover: true)
        #expect(machine.presentation == .expanded)
        #expect(machine.isOpenForAttention)
        _ = machine.handle(.attentionCleared, openOnHover: true)
        #expect(machine.presentation == .closed)
    }

    @Test func attentionStaysOpenWhileTheUserIsThere() {
        var machine = NotchInteraction()
        _ = machine.handle(.attentionRequested, openOnHover: true)
        _ = machine.handle(.pointerEntered, openOnHover: true)
        _ = machine.handle(.attentionCleared, openOnHover: true)
        #expect(machine.presentation == .expanded)
        // Leaving afterwards closes it the normal way.
        #expect(machine.handle(.pointerExited, openOnHover: true) == [.scheduleClose])
    }

    @Test func attentionNeverClosesANotchTheUserOpened() {
        var machine = NotchInteraction()
        _ = machine.handle(.clicked, openOnHover: true)
        _ = machine.handle(.attentionRequested, openOnHover: true)
        _ = machine.handle(.attentionCleared, openOnHover: true)
        #expect(machine.presentation == .expanded)
    }

    @Test func clickOutsideWhileClosedDoesNothing() {
        var machine = NotchInteraction()
        let effects = machine.handle(.clickedOutside, openOnHover: true)
        #expect(effects.isEmpty)
        #expect(machine.presentation == .closed)
    }
}
