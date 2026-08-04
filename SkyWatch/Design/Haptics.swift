import WatchKit

/// Every haptic the app plays, in one place, so it stays possible to answer "when does this thing
/// buzz me?" by reading a single file.
@MainActor
enum Haptics {
    /// A crown detent. Played per radius step, not per tick.
    static func crownDetent() {
        WKInterfaceDevice.current().play(.click)
    }

    /// A target has come inside 3 nm and below 8,000 ft for the first time this session.
    static func proximityAlert() {
        WKInterfaceDevice.current().play(.notification)
    }

    /// Pin or unpin from the list's swipe action.
    static func selectionChanged() {
        WKInterfaceDevice.current().play(.directionUp)
    }

    /// The tracked flight has landed — the alert you are actually waiting for.
    /// Stronger than the 30/15 ones so it cuts through even on wrist-down.
    static func flightLanded() {
        WKInterfaceDevice.current().play(.notification)
    }

    /// A 30/15-minute milestone: a short, polite tap that won't get annoying
    /// across a two-hour wait.
    static func flightMilestone() {
        WKInterfaceDevice.current().play(.click)
    }
}
