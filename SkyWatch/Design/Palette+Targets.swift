import SwiftUI

extension Palette {
    /// The colour a target is drawn in, resolved from what it *is* — never from where it happens to
    /// appear. This is the rule that keeps the scope an instrument: if something is amber, its
    /// position is uncertain; if it is red, the aircraft is declaring an emergency.
    ///
    /// Kept out of `Palette.swift` so that file stays free of app-only model types and can compile
    /// into the widget target unchanged.
    static func target(
        _ target: TrackedTarget,
        isSelected: Bool = false,
        isPinned: Bool = false
    ) -> Color {
        if target.aircraft.isAlerting { return warningRed }
        if isSelected || isPinned { return targetMagenta }
        if target.position.needsCaution { return cautionAmber }
        return primaryWhite
    }
}
