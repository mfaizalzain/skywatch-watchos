import SwiftUI

/// Glass-cockpit EFIS colour language. Every colour here carries a meaning, and views ask for it by
/// meaning rather than by name — there is deliberately no `Palette.blue`.
enum Palette {
    /// True black. On an OLED watch these pixels are off, which is real battery on Always-On.
    static let scopeBase = Color.black

    /// Reference data: range rings, secondary readouts, chrome.
    static let dataCyan = Color(red: 0x4F / 255, green: 0xD8 / 255, blue: 0xFF / 255)

    /// The selected or nearest target. Magenta is the PFD's "active" colour.
    static let targetMagenta = Color(red: 0xFF / 255, green: 0x5F / 255, blue: 0xD1 / 255)

    /// Stale positions, MLAT and estimated targets, reduced GPS accuracy.
    static let cautionAmber = Color(red: 0xFF / 255, green: 0xB0 / 255, blue: 0x20 / 255)

    /// Emergency squawks and any active `emergency` field.
    static let warningRed = Color(red: 0xFF / 255, green: 0x45 / 255, blue: 0x3A / 255)

    /// A live / landed / successfully completed state. Softer than the warning
    /// colours — it means "this is working", never "pay attention to this".
    static let successGreen = Color(red: 0x3D / 255, green: 0xE8 / 255, blue: 0x8A / 255)

    /// Primary numeric values.
    static let primaryWhite = Color(red: 0xF2 / 255, green: 0xF2 / 255, blue: 0xF7 / 255)

    // MARK: - Semantic accessors

    /// Always-On dims everything rather than hiding it: the scope stays readable, just quieter.
    static func dimmed(_ color: Color, isLuminanceReduced: Bool) -> Color {
        isLuminanceReduced ? color.opacity(0.55) : color
    }
}
