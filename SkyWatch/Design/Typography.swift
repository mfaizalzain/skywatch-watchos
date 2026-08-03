import SwiftUI

/// A three-step type scale, held everywhere.
///
/// Numeric readouts are monospaced *and* monospaced-digit: instrument values must not shift
/// horizontally when a digit changes, because a 40 mm display refreshing every ten seconds is
/// otherwise genuinely hard to read. That is a functional requirement, not a preference.
enum Typography {
    /// Large readouts: the nearest-target distance, detail-screen headline values.
    static let primaryValue = Font.system(.title3, design: .monospaced).monospacedDigit()

    /// Ordinary numeric values in list rows and detail rows.
    static let value = Font.system(.body, design: .monospaced).monospacedDigit()

    /// Small values: range-ring labels, badges, ages.
    static let smallValue = Font.system(.caption2, design: .monospaced).monospacedDigit()

    /// Field labels and chrome. Rounded, so it reads as interface rather than as data.
    static let label = Font.system(.caption, design: .rounded)
    static let smallLabel = Font.system(.caption2, design: .rounded)
    static let sectionHeader = Font.system(.caption, design: .rounded).weight(.semibold)
}

extension View {
    /// Callsigns and type codes: eight characters have to fit without truncating.
    func callsignStyle(_ font: Font = Font.system(.body, design: .monospaced)) -> some View {
        self.font(font)
            .fontWidth(.compressed)
            .lineLimit(1)
            .minimumScaleFactor(0.8)
    }
}
